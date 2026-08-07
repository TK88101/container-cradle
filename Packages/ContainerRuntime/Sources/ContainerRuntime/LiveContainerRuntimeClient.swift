import ContainerCore
import ContainerResource
import Foundation
import TerminalProgress

/// **真运行时。** `ContainerRuntimeClient` 的第三个实现（另两个是 Fake 与将来的 CLI 逃生舱）。
///
/// 因为 D1，把 App 从假数据切到真运行时，是 composition root 里**改一行**的事——
/// `ContainerListStore` 和所有 view 一个字都不用动。
///
/// ## 每个上游调用都套 `XPCTimeout`
///
/// 不可省（R5）：XPC 对端挂死时 `await` 永不返回，会冻住整个 supervisor——
/// 而进程还活着、图标还在、日志还在滚，看不出任何异常。
public struct LiveContainerRuntimeClient: ContainerRuntimeClient {

    private let upstream: any UpstreamClient
    private let paths: any PathChecker
    private let errors: RuntimeErrorMapper
    private let timeout: Duration

    /// stop 专用超时。**必须显著大于上游的 SIGTERM 优雅期**（`ContainerStopOptions
    /// .default.timeoutInSeconds == 5`，已核实源码）：stop 的语义就包含「最多等 5 秒
    /// 让容器优雅退出」，把它套在 5s 的全局 XPC 超时里，不吃 SIGTERM 的容器必然假超时
    /// ——CLI 里停成功，UI 报「停止失败」（Day 13 真机实测）。
    /// 「两个参数各自合理，凑在一起是灾难」（CLAUDE.md 坑清单）的又一例。
    private let stopTimeout: Duration

    /// 5s 优雅期 + SIGKILL + teardown 的余量。守它的测试：
    /// `defaultStopTimeoutCoversUpstreamGracePeriod`。
    public static let defaultStopTimeout: Duration = .seconds(15)

    /// create 专用超时。**必须显著大于 supervisor 档 `timeout`**：`create` 经
    /// `containerConfigFromFlags` → `ClientImage.fetch`，镜像不在本地时会触发下载，5s 必假超时
    /// （首次用某镜像的 create 必败——「编译绿测试绿看不出异常」型）。create 是 UI 一次性动作、
    /// **不在 supervisor reconcile 路径上**，故一个卡死也冻不住核心 supervisor——这个超时只是
    /// 「多久告诉用户它卡了」的 UX 上界，不参与熔断/退避（无「乘出真实时间」的复合风险）。
    /// 预填流程只提供已 pull 的镜像（§3.6 `ImageListStore` 下拉），本地装配通常几秒内完成。
    private let createTimeout: Duration

    /// 见上。默认 120s：本地镜像装配的宽裕头量。
    public static let defaultCreateTimeout: Duration = .seconds(120)

    /// usage enrichment 的**全局预算**（★R3/★R4/★R5，见 `VolumeUsageCollector`）。
    /// 与 per-call `timeout` 是两个尺度：后者钉单卷，前者钉整场。
    private let usageBudget: Duration

    /// - Parameter prober: 运行时死活的**唯一权威**（R14）。错误映射要问它，
    ///   而不是去猜 XPC 错误码的意思。
    public init(
        prober: any RuntimeProber = ApiserverProber(),
        timeout: Duration = .seconds(5),
        stopTimeout: Duration = Self.defaultStopTimeout,
        createTimeout: Duration = Self.defaultCreateTimeout
    ) {
        self.init(
            upstream: LiveUpstreamClient(),
            paths: FileSystemPathChecker(),
            prober: prober,
            timeout: timeout,
            stopTimeout: stopTimeout,
            createTimeout: createTimeout
        )
    }

    /// 测试入口：注入替身。`internal` —— 上游类型不会因此漏出 package。
    init(
        upstream: any UpstreamClient,
        paths: any PathChecker,
        prober: any RuntimeProber,
        timeout: Duration = .seconds(5),
        stopTimeout: Duration = Self.defaultStopTimeout,
        createTimeout: Duration = Self.defaultCreateTimeout,
        usageBudget: Duration = .seconds(8)
    ) {
        self.upstream = upstream
        self.paths = paths
        self.errors = RuntimeErrorMapper(prober: prober)
        self.timeout = timeout
        self.stopTimeout = stopTimeout
        self.createTimeout = createTimeout
        self.usageBudget = usageBudget
    }

    // MARK: - list

    public func list() async throws(RuntimeError) -> [Container] {
        let snapshots: [ContainerSnapshot]
        do {
            snapshots = try await XPCTimeout.race(after: timeout) {
                try await upstream.list()
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }

        do {
            return try snapshots.map(SnapshotMapper.map)
        } catch {
            // 映射失败 → **整个列表失败**，不静默丢掉那个容器（理由见 SnapshotMapper）。
            throw RuntimeError.operationFailed(reason: "Container mapping failed: \(error)")
        }
    }

    // MARK: - start

    /// 上游**没有 `start(id:)`**（已核实源码）。「把停着的容器拉起来」是一段序列，
    /// 照抄官方 `container start`：
    ///
    /// `get` → 幂等短路 → **virtiofs mount 源校验** → `bootstrap` → `process.start()`，失败回滚 `stop`。
    public func start(id: ContainerID) async throws(RuntimeError) {
        let snapshot = try await fetch(id)

        // 幂等短路。supervisor 会重复下达 start（轮询间隔内容器可能还没起来），
        // 「已经在跑」必须静默成功——官方 CLI 自己就这么短路的。
        guard snapshot.status != .running else { return }

        // ★★ **R13 的生死线，也是这个 App 的生死线。**
        //
        // 位置很重要：这段校验在下面那个 `do` 的**外面**。
        //
        // 放进 `do` 里，`.mountSourceUnavailable` 就会落进 catch，被 `errors.map` 重新包装成
        // `.operationFailed` → 判成 `.transient` → 计入熔断 → 退避 1→2→4→8→16 秒 →
        // **31 秒后熔断放弃**。而「Mac 重启后外置盘还没挂上」要几十秒到几分钟才就绪——
        // supervisor 会死在它唯一该活着的那一刻，且编译绿、测试绿、看不出任何异常。
        //
        // 靠「记得别在 catch 里包装它」是打地鼠。**靠代码形状**：它根本落不进那个 catch。
        // （`RuntimeErrorMapper` 里还有第二道：domain 错误原样放行。两道都在，因为这一条值得。）
        for mount in snapshot.configuration.mounts where mount.isVirtiofs {
            guard paths.fileExists(atPath: mount.source) else {
                throw RuntimeError.mountSourceUnavailable(path: mount.source)
            }
        }

        do {
            try await XPCTimeout.race(after: timeout) {
                try await upstream.launchInitProcess(snapshot)
            }
        } catch {
            // 失败必须回滚，否则留下半启动状态（官方 CLI 同样如此）。
            //
            // ★ **回滚本身也必须套超时**（codex review 抓到的 P1）。
            // `try?` 只吞错误，**吞不掉挂死**：XPC 若在这一句上不回话，`start()` 就永远不返回，
            // supervisor 当场冻住——正是 R5 要防的那件事，而且发生在最坏的位置：
            // bootstrap 刚失败的回滚路径，恰恰是 R13 场景（外置盘没挂上、容器起不来）的高频路径。
            //
            // 「每个上游调用都套 XPCTimeout」这句话写在本文件开头，却漏了这一句。
            // 注释拦不住漏写，测试才行（`rollbackDoesNotHangWhenStopHangs`）。
            try? await XPCTimeout.race(after: stopTimeout) {
                try await upstream.stop(id: id.rawValue)
            }

            throw await errors.map(error, containerID: id)
        }
    }

    // MARK: - stop

    public func stop(id: ContainerID) async throws(RuntimeError) {
        let snapshot = try await fetch(id)

        // 幂等：已经停了就静默成功。
        guard snapshot.status != .stopped else { return }

        do {
            try await XPCTimeout.race(after: stopTimeout) {
                try await upstream.stop(id: id.rawValue)
            }
        } catch {
            throw await errors.map(error, containerID: id)
        }
    }

    // MARK: - followLogs

    /// 上游约定 `logs(id:)` 返回 `[stdio, boot]`（已核实源码：`ContainerClient.swift:266`）。
    /// M4 明确不接 boot log（Day 9 计划 §1「明确不做」）——只 wrap `fhs[0]`。
    static let logBufferLimit = 1024

    /// 跟随容器 stdout。**裸流，未脱敏**——D-B'（Day 9 计划）钉死它唯一允许的消费者是
    /// core 的 `LogTailer`（`BoundaryScanner` 守）。这一层只负责把 fd 的字节接成完整行，
    /// 不做任何脱敏判断：脱敏需要该容器的密钥集合，那是 core 才有的信息。
    public func followLogs(id: ContainerID) async throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        let handles: [FileHandle]
        do {
            handles = try await XPCTimeout.race(after: timeout) {
                try await upstream.logs(id: id.rawValue)
            }
        } catch {
            throw await errors.map(error, containerID: id)
        }

        // 上游无 API 稳定性承诺（R1）——形状哪天变了，响亮地失败，不是对着越界下标崩溃。
        guard handles.count >= 2 else {
            for handle in handles { try? handle.close() }
            throw RuntimeError.operationFailed(
                reason: "Upstream logs(id:) returned an unexpected number of FileHandles: \(handles.count)"
            )
        }

        let stdio = handles[0]

        // stdio 之外的 handle 全部立刻关闭：boot log（`handles[1]`）不用，且上游若哪天
        // 多返回一个 fd（形状扩了），这里也不会把多出来的 fd 泄漏掉——只留 stdio 交给流持有。
        // 不然每次 follow 都会泄漏（codex review P1-6 关 boot；P2 关掉可能的余剰）。
        for handle in handles[1...] {
            try? handle.close()
        }

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(Self.logBufferLimit)) { continuation in
            // `nonisolated(unsafe)`：`readabilityHandler` 的闭包类型要求 `@Sendable`，
            // 但它背后是**一个** `FileHandle` 的**一条**串行 dispatch read source——
            // Apple 的文档与实现都保证同一个 handle 的回调不会并发触发，
            // 所以这里不存在真实的数据竞争，只是编译器看不穿这层保证。
            nonisolated(unsafe) var step = LogFollowStep()

            stdio.readabilityHandler = { handle in
                let data = handle.availableData

                switch step.handle(data: data, seekToEnd: { try handle.seekToEnd() }) {
                case .lines(let lines):
                    for line in lines { continuation.yield(line) }

                case .finished(let trailing, let error):
                    for line in trailing { continuation.yield(line) }
                    continuation.finish(throwing: error)
                }
            }

            // 三路终止（消费者取消 / 流内部 finish(throwing:) / 消费者优雅收工）都走这一个
            // 回调——`AsyncThrowingStream` 保证它恰好触发一次，不必在每个分支各自记得清理
            // （L6：桥必须关掉自己开的 fd，不然取消路径会悄悄泄漏）。
            continuation.onTermination = { _ in
                stdio.readabilityHandler = nil
                try? stdio.close()
            }
        }
    }

    // MARK: - stats

    /// 单发一次 = 一个瞬时计数器快照。CPU% 需要相邻两次样本算速率，那是
    /// core `StatsCollector` 的事，这里只负责「问一次，答一次」。
    public func stats(id: ContainerID) async throws(RuntimeError) -> ContainerStatsSample {
        do {
            let stats = try await XPCTimeout.race(after: timeout) {
                try await upstream.stats(id: id.rawValue)
            }
            return StatsMapper.map(stats)
        } catch {
            throw await errors.map(error, containerID: id)
        }
    }

    // MARK: - M5：volume（Day 10）

    public func listVolumes() async throws(RuntimeError) -> [Volume] {
        let configurations: [VolumeConfiguration]
        do {
            configurations = try await XPCTimeout.race(after: timeout) {
                try await upstream.listVolumes()
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }

        // enrichment：fail-soft（单卷失败→nil）+ 并发 ≤4 + 全局预算 no-wait + 闭门。
        // 每个 fetch 自己再套 per-call XPCTimeout——「每个上游调用无一豁免」（D-F）。
        let usageUpstream = self.upstream
        let perCallTimeout = self.timeout
        let collector = VolumeUsageCollector { name in
            try await XPCTimeout.race(after: perCallTimeout) {
                try await usageUpstream.volumeUsedBytes(name: name)
            }
        }
        let usage = await collector.collect(
            names: configurations.map(\.name),
            budget: usageBudget
        )

        return configurations.map { VolumeMapper.map($0, usedBytes: usage[$0.name]) }
    }

    /// identity-only（★R2）：裸 list 按名找，**不跑 usage**——这是删除前复核的快路径，
    /// 带 enrichment 的 `listVolumes()` 会把「复核 → 删除」的窗口撑成秒/分钟级。
    /// 不存在 = nil：not-found 没法从 XPC 错误文本可靠区分（R14），用列表缺席表达。
    public func inspectVolume(named name: String) async throws(RuntimeError) -> Volume? {
        let configurations: [VolumeConfiguration]
        do {
            configurations = try await XPCTimeout.race(after: timeout) {
                try await upstream.listVolumes()
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }

        guard let configuration = configurations.first(where: { $0.name == name }) else {
            return nil
        }
        return VolumeMapper.map(configuration, usedBytes: nil)
    }

    /// 语义 =「删除这个 identity」（★R3，最后防线）。store 的 `verifying` 给 UX；
    /// 这里的复核保证**绕过 store 直调也删不掉同名重建的新卷**。
    /// 复核与 delete 之间仍有 ms 级窗口（server 只有按名删）——已知残余，压不为零。
    public func deleteVolume(_ target: Volume) async throws(RuntimeError) {
        guard let current = try await inspectVolume(named: target.name) else {
            throw RuntimeError.operationFailed(
                reason: "volume '\(target.name)' no longer exists"
            )
        }
        guard current.matchesIdentity(of: target) else {
            throw RuntimeError.operationFailed(
                reason: "volume '\(target.name)' has changed since it was shown (it may have been recreated); refresh and confirm again"
            )
        }

        do {
            try await XPCTimeout.race(after: timeout) {
                try await upstream.deleteVolume(name: target.name)
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }
    }

    // MARK: - M5：image（Day 10）

    public func listImages() async throws(RuntimeError) -> ImageListSnapshot {
        let descriptions: [ImageDescription]
        do {
            descriptions = try await XPCTimeout.race(after: timeout) {
                try await upstream.listImages()
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }

        let infra = await resolveInfraFilter()

        let images: [ImageSummary]
        do {
            images = try descriptions
                .filter { !infra.refs.contains($0.reference) }
                .map(ImageMapper.map)
        } catch {
            // 映射失败 → 整个列表失败（Day 6 ④），不静默丢镜像。
            throw RuntimeError.operationFailed(reason: "Image mapping failed: \(error)")
        }

        return ImageListSnapshot(images: images, isInfraFilterAuthoritative: infra.isAuthoritative)
    }

    /// 删除前**重新**确认 infra 过滤（★R3）：UI 禁用只是 UX——旧快照 + config 变更的
    /// 窗口里，这里才是防线。非权威 → 拒绝（fail-closed）；命中 infra → 拒绝。
    public func deleteImage(reference: ImageRef) async throws(RuntimeError) {
        let infra = await resolveInfraFilter()

        guard infra.isAuthoritative else {
            throw RuntimeError.operationFailed(
                reason: "cannot confirm which images the runtime itself depends on; image deletion is disabled"
            )
        }
        guard !infra.refs.contains(reference.rawValue) else {
            throw RuntimeError.operationFailed(
                reason: "'\(reference.rawValue)' is a system image required by the runtime and cannot be deleted"
            )
        }

        do {
            try await XPCTimeout.race(after: timeout) {
                try await upstream.deleteImage(reference: reference.rawValue)
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }
    }

    /// config 真实加载成功 → (真实 refs, 权威)；失败（含超时）→ (stock 默认 refs, **非权威**)。
    /// 非权威时展示照常降级过滤，删除会被 `deleteImage` 的 guard 拒掉（D-C fail-closed）。
    private func resolveInfraFilter() async -> (refs: Set<String>, isAuthoritative: Bool) {
        do {
            let refs = try await XPCTimeout.race(after: timeout) {
                try await upstream.loadedInfraImageReferences()
            }
            return (refs, true)
        } catch {
            return (upstream.stockInfraImageReferences(), false)
        }
    }

    // MARK: - Day 16：创建 / 克隆 / pull / 删除容器

    // 五能力全部落地：create（T6.1）/ pullImage（T6.2）/ delete（T6.3）/ cloneTemplate（T6.4）/
    // create(clonedFrom:)（T6.5）。桩期的标记已全清——`RuntimeBoundaryTests.noDay16StubsRemain`
    // 守「桩标记 0 次出现」，防哪天有人又留一个 typed-throws 桩没接线就当完成了（T6.6）。

    /// 全新创建（能力 A）。判断在这一层：spec→inputs 纯映射（`CreationMapper`，已测）+ XPCTimeout +
    /// 错误映射 + id 回映。装配与 create 的副作用捆在 `upstream.createContainer`（不可测的直线段）。
    public func create(_ spec: ContainerCreationSpec) async throws(RuntimeError) -> ContainerID {
        let inputs = CreationMapper.inputs(for: spec)

        let rawID: String
        do {
            rawID = try await XPCTimeout.race(after: createTimeout) {
                try await upstream.createContainer(inputs)
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }

        // 上游无 API 稳定性承诺（R1）：回来的 id 映不回 domain → 响亮地失败，不静默。
        guard let id = ContainerID(rawID) else {
            throw RuntimeError.operationFailed(reason: "Upstream created a container with an unmappable id: \(rawID)")
        }
        return id
    }

    /// clone 预填（T6.4）：`get(source)` → `SnapshotMapper.cloneTemplate` 提 image+env+挂载摘要。
    /// `fetch` 已管 XPCTimeout + R14 错误映射；映射失败（坏 image）→ operationFailed，不静默。
    public func cloneTemplate(for source: ContainerID) async throws(RuntimeError) -> ContainerCloneTemplate {
        let snapshot = try await fetch(source)
        do {
            return try SnapshotMapper.cloneTemplate(from: snapshot)
        } catch {
            throw RuntimeError.operationFailed(reason: "Clone template mapping failed: \(error)")
        }
    }

    /// clone 提交（T6.5）：`get(source)` → **纯 `sanitizeForClone`**（§3.2 表，已测）→ create。
    /// now 在这里现取（`Date()`）注入纯 sanitizer，保持 sanitizer 无时钟依赖、可测。
    /// 与 fresh create 同一档 `createTimeout`（clone 也可能触发镜像补拉，off supervisor 路径）。
    public func create(
        clonedFrom source: ContainerID,
        name: ContainerName,
        envOverride: [EnvironmentVariable]?
    ) async throws(RuntimeError) -> ContainerID {
        let snapshot = try await fetch(source)
        let sanitized = CreationMapper.sanitizeForClone(
            snapshot.configuration,
            newID: name.value,
            envOverride: envOverride,
            creationDate: Date()
        )

        let rawID: String
        do {
            rawID = try await XPCTimeout.race(after: createTimeout) {
                try await upstream.createFromConfiguration(sanitized)
            }
        } catch {
            throw await errors.map(error, containerID: nil)
        }

        // 上游无 API 稳定性承诺（R1）：回来的 id 映不回 domain → 响亮失败，不静默。
        guard let id = ContainerID(rawID) else {
            throw RuntimeError.operationFailed(reason: "Upstream created a clone with an unmappable id: \(rawID)")
        }
        return id
    }

    /// image pull（§3.3 / T6.2）。**判断在这一层**：上游反向 XPC 分批投递事件 →
    /// `PullProgressAccumulator` 逐批喂 `PullMapper.folding`（跨批 add* 累加，T2b 回归的靶子）→
    /// 折叠出的快照 yield 进流。错误经 R14 判定映成 domain 错误、从流里抛出。
    ///
    /// ## 为什么不套 blanket `XPCTimeout`
    ///
    /// pull 是**无界流式下载**（镜像可能几百 MB、几分钟），且**有进度作 liveness 信号**——
    /// 一刀切超时会把正常的慢下载误杀。它又**不在 supervisor reconcile 路径上**：一次挂死冻不住
    /// 核心 supervisor。控制走**流取消**（`onTermination → task.cancel()`），同 `followLogs` 的
    /// 流式段一样不计时。真挂死（对端不回、也不投批）= 泄漏一个 orphan task，消费者不阻塞、UI
    /// 停在无进度态由用户取消——「宁可泄漏一个挂死的调用，也不冻住核心」（CLAUDE.md）。
    public func pullImage(_ reference: ImageRef) async throws(RuntimeError) -> AsyncThrowingStream<PullProgress, any Error> {
        let upstream = self.upstream
        let errors = self.errors
        let rawReference = reference.rawValue

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(Self.pullProgressBufferLimit)) { continuation in
            let task = Task {
                let accumulator = PullProgressAccumulator()
                do {
                    try await upstream.pullImage(reference: rawReference) { events in
                        continuation.yield(await accumulator.fold(events))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: await errors.map(error, containerID: nil))
                }
            }
            // 消费者取消 / 收工 → 取消底层 pull 任务（对端若不响应取消，则任务泄漏，见方法注释）。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// pull 进度的缓冲上界。进度是「显示最新累积态」，落后的中间帧丢弃无害——留一小段
    /// 只为不丢相邻的 phase 切换（Fetching→Unpacking）。
    static let pullProgressBufferLimit = 64

    /// 删除容器的确定序列（§3.4 / codex #12）。**not-found 与 runtime-down 不可混**：
    /// 1. 前置复核（`fetch` 已按 R14 把 not-found→`.containerNotFound`、runtime-down→`.runtimeUnavailable`）。
    /// 2. `delete(force: true)`（force 让删 running 走 server SIGKILL+cleanup）。
    /// 3. 报错 → **仅 runtime 可达才复核**：已不存在=幂等成功；仍在=真失败；runtime 死了=原样抛
    ///    （**绝不**把「复核失败」解读成「已删成功」——那会谎报成功）。
    public func delete(id: ContainerID) async throws(RuntimeError) {
        // 1. 前置复核。**存在性没确立就绝不当 absent**（codex #12）：确实不存在 → containerNotFound；
        //    runtime down / 超时 / 映射失败等无法确定存在性的失败由 `containerExists` 原样上抛
        //    （不谎称 not-found）。
        guard try await containerExists(id) else {
            throw RuntimeError.containerNotFound(id)
        }

        // 2. delete(force: true)。
        do {
            try await XPCTimeout.race(after: timeout) {
                try await upstream.deleteContainer(id: id.rawValue, force: true)
            }
        } catch {
            let mapped = await errors.map(error, containerID: id)

            // 3. runtime 不可达 → 原样抛，不复核（复核也会失败、白跑一次 XPC；且绝不把 runtime-down
            //    读成 not-found，codex #12）。
            if case .runtimeUnavailable = mapped { throw mapped }

            // runtime 可达 → 复核。**只有确定「已不存在」才当幂等成功**；复核本身若无法确定存在性
            //    （超时 / 映射失败 / runtime 刚死）→ `containerExists` 抛出，这里抛回**原始 delete 错误**，
            //    绝不因为「复核也没取到」就谎称删成功。
            let stillExists: Bool
            do {
                stillExists = try await containerExists(id)
            } catch {
                throw mapped
            }
            if stillExists { throw mapped }
            // 确认已不存在 → delete 的报错是虚惊，幂等成功。
        }
    }

    // MARK: -

    /// 容器是否**确实存在**。只有确定的信号才回答：`fetch` 成功 = 存在；映射出 `.containerNotFound`
    /// = 确实不存在。runtime 不可达 / XPC 超时 / 映射失败等**无法确定存在性**的错误一律**上抛**——
    /// 绝不塌缩成「不存在」（codex #12 / R14）：存在性没确立就当 absent，会把失败的 delete 谎称成功、
    /// 或把一次超时报成 not-found。穷尽 `switch`（无 default）：`RuntimeError` 加 case 时编译器强制在
    /// 这里重新决定它算不算「确定不存在」。
    private func containerExists(_ id: ContainerID) async throws(RuntimeError) -> Bool {
        do {
            _ = try await fetch(id)
            return true
        } catch {
            switch error {
            case .containerNotFound:
                return false
            case .runtimeUnavailable, .operationFailed, .mountSourceUnavailable:
                throw error
            }
        }
    }

    private func fetch(_ id: ContainerID) async throws(RuntimeError) -> ContainerSnapshot {
        do {
            return try await XPCTimeout.race(after: timeout) {
                try await upstream.get(id: id.rawValue)
            }
        } catch {
            throw await errors.map(error, containerID: id)
        }
    }
}

/// pull 进度的**跨批累积器**。`PullMapper.folding` 是纯的（每批产出一个新快照），但流式 pull
/// 分批投递、`add*` 族要跨批累加——「当前累积态」得有地方存活到下一批。上游的 `onProgress` 是
/// `@Sendable async` 回调，用 actor 持有 `current` 最稳：不赌调用方串行投递，也满足 `@Sendable`。
private actor PullProgressAccumulator {
    private var current = PullMapper.initial

    /// 折叠一批事件进累积态，返回那一刻的合法快照（`PullProgress` 既是累积态又是对外快照）。
    func fold(_ events: [ProgressUpdateEvent]) -> PullProgress {
        current = PullMapper.folding(current, with: events)
        return current
    }
}
