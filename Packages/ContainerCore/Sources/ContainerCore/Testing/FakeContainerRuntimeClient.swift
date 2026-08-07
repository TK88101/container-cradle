/// 内存实现的运行时，用来在没有 apiserver、没有真容器的地方驱动整个 App。
///
/// ## 它为什么住在 `Sources/` 而不是 test target
///
/// M0 的验收是「菜单栏点开，看见 3 个假容器」——那要求 **app target** 能构造它，
/// 而 app target 链不到 test target。SwiftUI Preview 同理。
/// 代价（已接受）：产品二进制里带一份 Fake。
///
/// 它不破坏 D1：Fake 恰恰是零上游依赖的——那正是它存在的意义。
///
/// ## 语义要对齐真运行时，尤其这两条
///
/// - **起停幂等**：supervisor 会重复下达 `start`。对「已在跑」抛错，会测出一个真运行时
///   并不存在的问题（官方 CLI 自己就短路：`if container.status == .running { return }`）。
/// - **失败要能注入**：D3 的整个理由是「apiserver 挂了又起来」。这条路径不能注入，
///   supervisor 的核心价值就没有测试覆盖。
public actor FakeContainerRuntimeClient: ContainerRuntimeClient {

    /// 可被注入失败的操作。按操作而非全局——apiserver 半死不活时
    /// 「list 通了但 start 失败」是真实存在的状态，一个全局开关表达不出来。
    public enum Operation: Sendable, Hashable {
        case list
        case start
        case stop
        case followLogs
        case stats
        case listVolumes
        case inspectVolume
        case deleteVolume
        case listImages
        case deleteImage
        // Day 16
        case create
        case cloneTemplate
        case createClone
        case pullImage
        case deleteContainer
    }

    /// 调用流水的一条。
    ///
    /// supervisor 的验收命题是「它有没有对白名单里的容器**下达过** start」——
    /// 那是关于副作用的断言，光看最终状态答不了：容器最后在跑，
    /// 可能是 supervisor 拉的，也可能它本来就在跑。
    public enum Call: Sendable, Equatable {
        case list
        case start(ContainerID)
        case stop(ContainerID)
        case followLogs(ContainerID)
        case stats(ContainerID)
        case listVolumes
        case inspectVolume(String)
        case deleteVolume(String)
        case listImages
        case deleteImage(ImageRef)
        // Day 16
        case create(ContainerName)
        case cloneTemplate(ContainerID)
        case createClone(source: ContainerID, name: ContainerName)
        case pullImage(ImageRef)
        case deleteContainer(ContainerID)
    }

    /// 用数组而非字典存：`list()` 的返回顺序必须**确定**，
    /// 否则断言顺序的测试会随字典哈希随机红。
    private var containers: [Container]
    private var injected: [Operation: RuntimeError] = [:]

    /// M5：volume / image 的内存存储。同 `containers`：数组保证返回顺序确定。
    private var volumes: [Volume]
    private var images: [ImageSummary]

    /// `listImages()` 快照携带的权威旗标（D-C：非权威 → UI 禁删）。
    private var infraFilterAuthoritative: Bool

    /// `followLogs` 要按顺序吐出的行。默认空——不配置就是一个立刻结束的空流。
    private var logLines: [LogLine] = []

    /// 吐完 `logLines` 之后：`true` = 流**挂起**（不 finish，模拟仍然连着但暂时没有新行）；
    /// `false`（默认）= 正常 `finish()`。「挂起」是 T6 明确要求的注入能力——用来测
    /// `LogTailer.cancel()` 能不能在一条永不结束的流上正确收工。
    private var logStreamHangsAfterLines = false

    /// `stats` 要按顺序吐出的样本（FIFO）。取空之后重复返回最后一个（若从未配置过，
    /// 返回一个全 `nil` 的样本——「问了，但什么都没测到」，不是崩溃也不是编造数字）。
    private var statsSamples: [ContainerStatsSample] = []

    /// `pullImage` 要按顺序 yield 的进度。默认空——不配置就是一个立刻 finish 的空流。
    private var pullProgressUpdates: [PullProgress] = []

    /// pull 流可控 probe（Day 16 T9.0，codex #4）：`true` 时 `pullImage` 吐完初始 `pullProgressUpdates`
    /// 后**挂起**（不 finish），continuation 存 `pullContinuation` 供测试主动 yield/finish/fail——
    /// 测得到「取消后旧流迟到事件被 store 令牌拦下」这类竞态（followLogs 那种纯挂起测不到主动投递）。
    private var pullStreamSuspends = false
    private var pullContinuation: AsyncThrowingStream<PullProgress, any Error>.Continuation?

    /// 普通（非挂起）pull 流：yield 完以此**错误**结束（`finish(throwing:)`）而非正常 finish——
    /// 测「流内失败」不必用挂起流（避免「ready 前操作 → 冻死」的赛跑）。nil = 正常 finish。
    private var pullStreamError: RuntimeError?

    /// 挂起 pull 流的「建流就绪」同步点：`pullImage` 设好 `pullContinuation` 后置 true 并 resume 等待者。
    /// 测试**必须**先 `awaitPullStreamReadyForTests()` 再主动 yield/finish/fail——否则可能在
    /// continuation 还是 nil 时操作、流永久挂起 → `awaitCurrentTaskForTests` 冻死（本仓挂起流坑）。
    private var pullStreamReady = false
    private var pullReadyWaiters: [CheckedContinuation<Void, Never>] = []

    /// clone create 每次收到的 `envOverride` 参数（Day 16 T9.0，codex #6）——**仅测试可见**。
    /// 数组（非单槽 Optional）区分「没调」（空）vs「调了传 nil」（`[nil]`）；`Call.createClone`
    /// 不记它（避免改 `Call` enum 炸既有 T6/T8 断言）。
    public private(set) var createCloneEnvOverrides: [[EnvironmentVariable]?] = []

    /// 调用流水，含**失败的调用**——「试过但失败了」和「压根没试」是两码事，
    /// supervisor 的重试测试正是要区分这两个。
    public private(set) var calls: [Call] = []

    public init(
        containers: [Container],
        volumes: [Volume] = [],
        images: [ImageSummary] = [],
        isInfraFilterAuthoritative: Bool = true
    ) {
        self.containers = containers
        self.volumes = volumes
        self.images = images
        self.infraFilterAuthoritative = isInfraFilterAuthoritative
    }

    /// 切换 infra 过滤的权威旗标（模拟 config 加载失败的退化态）。
    public func setInfraFilterAuthoritative(_ authoritative: Bool) {
        infraFilterAuthoritative = authoritative
    }

    /// 注入（或用 `nil` 撤销）某个操作的失败。
    public func inject(_ error: RuntimeError?, for operation: Operation) {
        injected[operation] = error
    }

    /// 配置 `followLogs` 要吐出的行。`hangsAfterLines`：吐完之后是否**挂起**
    /// （不 `finish()`，模拟一条仍连着但暂时没有新行的流）而不是正常结束。
    public func setLogLines(_ lines: [LogLine], hangsAfterLines: Bool = false) {
        logLines = lines
        logStreamHangsAfterLines = hangsAfterLines
    }

    /// 配置 `stats` 要按顺序吐出的样本。
    public func setStatsSamples(_ samples: [ContainerStatsSample]) {
        statsSamples = samples
    }

    /// 配置 `pullImage` 要按顺序 yield 的进度更新。
    public func setPullProgress(_ updates: [PullProgress]) {
        pullProgressUpdates = updates
    }

    /// pull 流是否在吐完初始 updates 后挂起（供 T9.2 取消/竞态测试）。见 `pullContinuation`。
    public func setPullStreamSuspends(_ on: Bool) {
        pullStreamSuspends = on
    }

    /// 主动向挂起的 pull 流投递一条进度（模拟后台流迟到事件）。
    public func yieldPullProgress(_ update: PullProgress) {
        pullContinuation?.yield(update)
    }

    /// 主动正常结束挂起的 pull 流（模拟后台拉取完成）。
    public func finishPullStream() {
        pullContinuation?.finish()
        pullContinuation = nil
    }

    /// 主动以错误结束挂起的 pull 流（模拟流内失败）。
    public func failPullStream(_ error: RuntimeError) {
        pullContinuation?.finish(throwing: error)
        pullContinuation = nil
    }

    /// 普通 pull 流的流内错误（yield 完以它结束）。见 `pullStreamError`。
    public func setPullStreamError(_ error: RuntimeError?) {
        pullStreamError = error
    }

    /// 等挂起 pull 流建流就绪（`pullContinuation` 已设）——主动 yield/finish/fail **之前**必须先等它。
    public func awaitPullStreamReadyForTests() async {
        if pullStreamReady { return }
        await withCheckedContinuation { pullReadyWaiters.append($0) }
    }

    private func markPullStreamReady() {
        pullStreamReady = true
        let waiters = pullReadyWaiters
        pullReadyWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - ContainerRuntimeClient

    public func list() throws(RuntimeError) -> [Container] {
        calls.append(.list)
        if let error = injected[.list] { throw error }
        return containers
    }

    public func start(id: ContainerID) throws(RuntimeError) {
        try transition(id: id, to: .running, operation: .start, call: .start(id))
    }

    public func stop(id: ContainerID) throws(RuntimeError) {
        try transition(id: id, to: .stopped, operation: .stop, call: .stop(id))
    }

    /// **不是 `async`**（虽然 protocol 要求 `async`，这里天然满足——同步函数能满足
    /// async 要求，反过来不行）。构造一个内存里的假流，不碰任何真实 IO。
    public func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        calls.append(.followLogs(id))
        if let error = injected[.followLogs] { throw error }

        let lines = logLines
        let hangs = logStreamHangsAfterLines

        return AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            // `hangs`：刻意不调 `finish()`——流留在「打开但没有更多行」的状态，
            // 直到消费者的 Task 被取消（触发 `onTermination(.cancelled)`）。
            guard !hangs else { return }
            continuation.finish()
        }
    }

    public func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample {
        calls.append(.stats(id))
        if let error = injected[.stats] { throw error }

        guard !statsSamples.isEmpty else {
            return ContainerStatsSample()
        }
        return statsSamples.removeFirst()
    }

    // MARK: - M5：volume / image

    public func listVolumes() throws(RuntimeError) -> [Volume] {
        calls.append(.listVolumes)
        if let error = injected[.listVolumes] { throw error }
        return volumes
    }

    /// identity-only：**usedBytes 恒 nil**（protocol 语义，live 实现走裸 list 不取 usage）。
    public func inspectVolume(named name: String) throws(RuntimeError) -> Volume? {
        calls.append(.inspectVolume(name))
        if let error = injected[.inspectVolume] { throw error }

        guard let found = volumes.first(where: { $0.name == name }) else { return nil }
        return Volume(
            name: found.name,
            creationDate: found.creationDate,
            source: found.source,
            sizeMaxBytes: found.sizeMaxBytes,
            usedBytes: nil
        )
    }

    /// ★R3 的语义对齐：**「删除这个 identity」**。同名但 fingerprint 不同（同名重建）
    /// → 拒绝且不动数据——live client 的最后防线就是这么工作的，Fake 不许更松。
    public func deleteVolume(_ target: Volume) throws(RuntimeError) {
        calls.append(.deleteVolume(target.name))
        if let error = injected[.deleteVolume] { throw error }

        guard let index = volumes.firstIndex(where: { $0.name == target.name }) else {
            throw .operationFailed(reason: "volume '\(target.name)' not found")
        }
        guard volumes[index].matchesIdentity(of: target) else {
            throw .operationFailed(reason: "volume '\(target.name)' identity changed since it was shown")
        }
        volumes.remove(at: index)
    }

    public func listImages() throws(RuntimeError) -> ImageListSnapshot {
        calls.append(.listImages)
        if let error = injected[.listImages] { throw error }
        return ImageListSnapshot(images: images, isInfraFilterAuthoritative: infraFilterAuthoritative)
    }

    public func deleteImage(reference: ImageRef) throws(RuntimeError) {
        calls.append(.deleteImage(reference))
        if let error = injected[.deleteImage] { throw error }

        // 语义对齐 live（★R3 / codex code review P2）：非权威过滤下 live 会 fail-closed
        // 拒绝删除。Fake 若在这里放行，「非权威仍可删除」的回归就会在 Fake 上测出假绿。
        guard infraFilterAuthoritative else {
            throw .operationFailed(reason: "cannot confirm infra image filter; image deletion is disabled")
        }

        guard let index = images.firstIndex(where: { $0.reference == reference }) else {
            throw .operationFailed(reason: "image '\(reference.rawValue)' not found")
        }
        images.remove(at: index)
    }

    // MARK: - Day 16：创建 / 克隆 / pull / 删除容器

    /// 全新创建：把容器以 **stopped** 落进内存（create 不启动它——「建后启」是两步），返回其 identity。
    /// 注入失败在落容器**之前**抛：失败的 create 必须不留下半个容器。
    public func create(_ spec: ContainerCreationSpec) throws(RuntimeError) -> ContainerID {
        calls.append(.create(spec.name))
        if let error = injected[.create] { throw error }

        let id = try requireID(from: spec.name.value)
        containers.append(
            Container(id: id, image: spec.image, state: .stopped, environment: spec.environment)
        )
        return id
    }

    /// clone 预填：从源容器提 image + env，挂载摘要计数默认全 0（Fake 不建模挂载明细）。
    public func cloneTemplate(for source: ContainerID) throws(RuntimeError) -> ContainerCloneTemplate {
        calls.append(.cloneTemplate(source))
        if let error = injected[.cloneTemplate] { throw error }

        guard let found = containers.first(where: { $0.id == source }) else {
            throw .containerNotFound(source)
        }
        return ContainerCloneTemplate(
            image: found.image,
            environment: found.environment,
            mountSummary: MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0)
        )
    }

    /// 以源为模板新建：复制 image；`envOverride` 非 nil 用它，否则原样克隆源 env。新容器 stopped 落库。
    public func create(
        clonedFrom source: ContainerID,
        name: ContainerName,
        envOverride: [EnvironmentVariable]?
    ) throws(RuntimeError) -> ContainerID {
        calls.append(.createClone(source: source, name: name))
        createCloneEnvOverrides.append(envOverride)
        if let error = injected[.createClone] { throw error }

        guard let template = containers.first(where: { $0.id == source }) else {
            throw .containerNotFound(source)
        }
        let id = try requireID(from: name.value)
        containers.append(
            Container(
                id: id,
                image: template.image,
                state: .stopped,
                environment: envOverride ?? template.environment
            )
        )
        return id
    }

    /// pull：yield 配置好的进度后 finish（同 `followLogs` 的同步假流）。注入失败在建流阶段抛（typed）。
    /// `pullStreamSuspends` 时改用可控 probe：吐完初始 updates 后挂起，continuation 存起来供
    /// `yieldPullProgress`/`finishPullStream`/`failPullStream` 主动驱动（T9.0，codex #4）。
    public func pullImage(_ reference: ImageRef) throws(RuntimeError) -> AsyncThrowingStream<PullProgress, any Error> {
        calls.append(.pullImage(reference))
        if let error = injected[.pullImage] { throw error }

        let updates = pullProgressUpdates
        let streamError = pullStreamError
        guard pullStreamSuspends else {
            return AsyncThrowingStream { continuation in
                for update in updates {
                    continuation.yield(update)
                }
                if let streamError {
                    continuation.finish(throwing: streamError)
                } else {
                    continuation.finish()
                }
            }
        }

        pullStreamReady = false
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: PullProgress.self,
            throwing: (any Error).self
        )
        for update in updates {
            continuation.yield(update)
        }
        pullContinuation = continuation
        markPullStreamReady()
        return stream
    }

    /// 删除容器：不存在 → `.containerNotFound`（不静默）；存在 → 移除。
    public func delete(id: ContainerID) throws(RuntimeError) {
        calls.append(.deleteContainer(id))
        if let error = injected[.deleteContainer] { throw error }

        guard let index = containers.firstIndex(where: { $0.id == id }) else {
            throw .containerNotFound(id)
        }
        containers.remove(at: index)
    }

    // MARK: -

    /// 从名字构 `ContainerID`（create / create-clone 共用）。因 `ContainerName` 正则严于
    /// `ContainerID`（只挡空白），实践上必成功；这条 guard 只挡「有人绕过 ContainerName 直塞空串」。
    private func requireID(from name: String) throws(RuntimeError) -> ContainerID {
        guard let id = ContainerID(name) else {
            throw .operationFailed(reason: "invalid container name '\(name)'")
        }
        return id
    }

    /// 幂等是**天然**的，不靠特判：目标状态直接赋值，已经是那个状态就等于没动。
    ///
    /// 注入的失败在改状态**之前**抛：失败的 `start` 必须让容器留在原地，
    /// 否则 supervisor 的「失败后重试」测试会因为状态已经变了而假绿。
    private func transition(
        id: ContainerID,
        to state: ContainerState,
        operation: Operation,
        call: Call
    ) throws(RuntimeError) {
        calls.append(call)
        if let error = injected[operation] { throw error }

        guard let index = containers.firstIndex(where: { $0.id == id }) else {
            throw .containerNotFound(id)
        }

        let existing = containers[index]
        containers[index] = Container(
            id: existing.id,
            image: existing.image,
            state: state,
            environment: existing.environment
        )
    }
}

// MARK: - 演示数据

extension FakeContainerRuntimeClient {

    /// M0 验收用的三个容器：一个在跑、一个停着、一个在停——菜单要能把三种状态都渲染出来。
    ///
    /// `open-connector` 的 env 里刻意放一个**假**密钥：它让「详情页渲染 env」这条路
    /// 从第一天起就在 D2 的保护下。真机上这个容器的 env 里确实有明文密钥（CLAUDE.md），
    /// 演示数据长得不像真的，等于给自己留一个「上线才发现」的坑。
    /// 这里的值是编的，不是真密钥。
    public static var preview: FakeContainerRuntimeClient {
        FakeContainerRuntimeClient(containers: [
            Container(
                id: ContainerID("open-connector")!,
                image: ImageRef("oomol/connector:1.0")!,
                state: .running,
                environment: [
                    EnvironmentVariable(key: "PATH", value: SecretString("/usr/bin:/bin")),
                    EnvironmentVariable(
                        key: "OOMOL_CONNECT_ENCRYPTION_KEY",
                        value: SecretString("fake-not-a-real-key")
                    ),
                ]
            ),
            Container(
                id: ContainerID("postgres")!,
                image: ImageRef("docker.io/library/postgres:16")!,
                state: .stopped,
                environment: []
            ),
            Container(
                id: ContainerID("redis")!,
                image: ImageRef("docker.io/library/redis:7")!,
                state: .stopping,
                environment: []
            ),
        ])
    }
}
