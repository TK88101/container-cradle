import ContainerAPIClient
import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// **真机 T8：create / clone / pull / delete 端到端。**
///
/// 前面单测喂的都是 Fake——create 序列（`containerConfigFromFlags` + `createContainer`）、
/// clone 序列（`get` → `sanitizeForClone` → `createFromConfiguration`）、pull 反向进度流、
/// delete 确定序列这四条真 XPC 路径**一次都没跑过**（「被豁免的那一层最容易藏 P1」，CLAUDE.md）。
/// 这里跑真的。
///
/// ## 靶子纪律（同 M5 集成测试）
///
/// - 靶子**自建**：`cof-test-<UUID>`。容器按前缀清扫即可——`cof-test-` + 随机 UUID 用户不会撞，
///   且删一个停着的一次性容器风险低（CLAUDE.md 的严格删除纪律是给 **volume** 的：卷里可能是
///   加密后不可恢复的数据）。
/// - **卷**严格双匹配（前缀 ∧ owner label）才删；同前缀无 label 的报告不删（误删 = 事故）。
/// - `defer` 兜不住早退/进程被 kill——每条测试**开头先 `sweepLeftovers()`** 扫上一次的残留，
///   happy-path 显式删，失败路径由 CLI 逃生舱 `container delete --force` + 下轮 sweep 兜底（④）。
/// - clone 源含 **volume + bind + tmpfs 三类挂载**（codex #13）：app 自己的 create 只建命名卷，
///   故源走 **CLI 逃生舱**造（`-v vol:/p`、`-v /host:/p`、`--tmpfs /p`），被测的 clone 走 app 路径。
///
/// `INTEGRATION=1 swift test` 才跑。
/// **`.serialized` 是必需不是偏好**：Swift Testing 默认并发跑同 suite 内的测试（实测三条同时 started）；
/// 而 `sweepLeftovers()` 删**全部** `cof-test-` 容器/自建卷——并发下一条测试的 sweep 会删掉另一条**在飞**
/// 的靶子（容器只按前缀清，双匹配只护卷）。串行后 sweep 只会遇到上一条已结束/上一轮的残留（codex/altitude P1）。
@Suite(
    "真机 T8：create / clone / pull / delete 生命周期",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1"),
    .serialized
)
struct CreateCloneIntegrationTests {

    private static let namePrefix = "cof-test-"
    private static let ownerLabelKey = "com.cradleoffilth.test.owner"
    private static let ownerLabelValue = "t8-integration"
    private static let containerBinary = "/usr/local/bin/container"
    /// 小体积公开镜像；create/clone 复用，pull 单测另用（见 pull 测试注释）。
    private static let testImage = "docker.io/library/alpine:latest"

    private func uniqueName() -> String { Self.namePrefix + UUID().uuidString.lowercased() }

    // MARK: - CLI 逃生舱（只用于造源/兜底清理；被测路径永远走 LiveContainerRuntimeClient）

    /// 返回 (退出码, stdout+stderr 合并输出)。
    ///
    /// **合并成单管道 = 结构上不可能死锁**：两条独立管道时若只排空一条、另一条被子进程写满 OS 缓冲
    /// （`container image pull` 会流大量进度），子进程阻塞在 `write()` → 永不退出 → 被排空那条永不 EOF
    /// → 双方永久互等（codex/efficiency P1，冷缓存 pull 必现，非边角）。单管道单读者持续排空，子进程写得
    /// 畅通，退出即 EOF——排空顺序依赖被彻底消除。
    @discardableResult
    private func cli(_ args: [String]) throws -> (code: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.containerBinary)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe   // stderr 并入 stdout：单管道，无排空顺序依赖。
        try proc.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        return (proc.terminationStatus, output)
    }

    /// 镜像不在本机就 pull（create 不保证自动拉；idempotent）。
    private func ensureTestImagePresent() throws {
        let result = try cli(["image", "inspect", Self.testImage])
        guard result.code != 0 else { return }
        let pull = try cli(["image", "pull", Self.testImage])
        guard pull.code == 0 else {
            throw SmokeError.setupFailed("pull \(Self.testImage) 失败：\(pull.output)")
        }
    }

    /// 清上一次运行的残留。容器按前缀；卷按前缀 ∧ owner label 双匹配。
    private func sweepLeftovers() async throws {
        let client = LiveContainerRuntimeClient()
        // list 失败就让 sweep 抛（与下面 volume 半边一致）：`try?` 静默空转会把残留藏起来（codex P2）。
        for container in try await client.list()
        where container.id.rawValue.hasPrefix(Self.namePrefix) {
            try? await client.delete(id: container.id)
        }
        for config in try await ClientVolume.list() where config.name.hasPrefix(Self.namePrefix) {
            if config.labels[Self.ownerLabelKey] == Self.ownerLabelValue {
                try? await ClientVolume.delete(name: config.name)
            } else {
                Issue.record("同前缀但无 owner label 的卷 '\(config.name)'——非本测试自建，跳过不删，请人工确认")
            }
        }
    }

    private enum SmokeError: Error { case setupFailed(String) }

    // MARK: - ① create → .stopped → delete

    @Test("① app create → 落地为 .stopped → app delete → 消失")
    func createStoppedThenDelete() async throws {
        try await sweepLeftovers()
        try ensureTestImagePresent()

        let client = LiveContainerRuntimeClient()
        let name = try ContainerName(uniqueName())
        let image = try #require(ImageRef(Self.testImage))
        let spec = try ContainerCreationSpec(name: name, image: image, volumeMounts: [], environment: [])

        do {
            let id = try await client.create(spec)

            // create 不 start：落地就是 stopped。
            let listed = try await client.list()
            let created = try #require(listed.first { $0.id == id }, "create 返回的 id 不在 list 里")
            #expect(created.state == .stopped, "create 出来应是 .stopped，实际 \(created.state)")

            // 显式删 → 从 list 消失（delete 的确定序列真机验证）。
            try await client.delete(id: id)
            let after = try await client.list()
            #expect(!after.contains { $0.id == id }, "delete 后仍在 list 里")
        } catch {
            _ = try? cli(["delete", "--force", name.value])   // CLI 逃生舱兜底（④）
            throw error
        }
    }

    // MARK: - ② clone：源含 volume+bind+tmpfs → app clone → 验挂载保全 → 删源与克隆

    @Test("② clone 源含三类挂载 → app clone → MountSummary 保全 volume/bind/tmpfs → 共存 → 删两者")
    func cloneReplicatesAllThreeMountKinds() async throws {
        try await sweepLeftovers()
        try ensureTestImagePresent()

        let client = LiveContainerRuntimeClient()
        let volumeName = uniqueName() + "-vol"
        let sourceName = uniqueName() + "-src"
        let cloneName = uniqueName() + "-clone"
        let bindDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(uniqueName() + "-bind", isDirectory: true)

        // 兜底清理（每个失败路径都经这里）。容器按名 CLI 强删——**连「create 建了容器却在返回 id 前
        // 抛错/超时」这种拿不到 cloneID 的情形也兜得住**（codex P1：名字提前定好，不依赖 create 返回值）；
        // 卷 + bind 目录一并清。
        func teardown() async {
            _ = try? cli(["delete", "--force", sourceName])
            _ = try? cli(["delete", "--force", cloneName])
            try? await ClientVolume.delete(name: volumeName)
            try? FileManager.default.removeItem(at: bindDir)
        }

        do {
            // 源的命名卷走上游 API 建（带 owner label，让 sweep 的严格双匹配能兜住它）。
            _ = try await ClientVolume.create(
                name: volumeName,
                labels: [Self.ownerLabelKey: Self.ownerLabelValue]
            )
            try FileManager.default.createDirectory(at: bindDir, withIntermediateDirectories: true)

            // 源走 CLI 逃生舱造：一条命名卷挂载 + 一条 bind + 一条 tmpfs（app create 造不出后两类）。
            let create = try cli([
                "create", "--name", sourceName, "-l", "\(Self.ownerLabelKey)=\(Self.ownerLabelValue)",
                "-v", "\(volumeName):/data",
                "-v", "\(bindDir.path):/host",
                "--tmpfs", "/scratch",
                Self.testImage,
            ])
            guard create.code == 0 else {
                throw SmokeError.setupFailed("CLI 造 clone 源失败：\(create.output)")
            }

            let sourceID = try #require(ContainerID(sourceName), "源 id 构造失败")

            // cloneTemplate 从真 snapshot 提 MountSummary：三类都得数出来（SnapshotMapper 分类真机验证）。
            let sourceTemplate = try await client.cloneTemplate(for: sourceID)
            #expect(sourceTemplate.mountSummary.volumeCount >= 1, "源没数出命名卷")
            #expect(sourceTemplate.mountSummary.bindCount >= 1, "源没数出 bind 挂载")
            #expect(sourceTemplate.mountSummary.tmpfsCount >= 1, "源没数出 tmpfs 挂载")

            // 被测：app clone（get → sanitizeForClone → createFromConfiguration 全序列真 XPC）。
            let cloneID = try await client.create(
                clonedFrom: sourceID, name: try ContainerName(cloneName), envOverride: nil
            )

            // clone 成功 + 源存活 + 挂载保全 = 整条真-XPC 序列跑通。**不**声称「共存证明身份重置」：
            // 源只 create 未 start，未必有运行时分配的 MAC 可撞（codex/altitude P2）——networks/MAC/hostname
            // 重置由 `CloneSanitizeTests` golden 逐字段钉死，那才是重置的证明；这里只验序列跑通 + 挂载没丢。
            let listed = try await client.list()
            #expect(listed.contains { $0.id == cloneID }, "clone 不在 list 里")
            #expect(listed.contains { $0.id == sourceID }, "clone 后源消失了（不该动源）")

            // 挂载保全：克隆体的 MountSummary 三类计数与源一致（sanitize 不丢挂载）。
            let cloneTemplate = try await client.cloneTemplate(for: cloneID)
            #expect(cloneTemplate.mountSummary.volumeCount == sourceTemplate.mountSummary.volumeCount)
            #expect(cloneTemplate.mountSummary.bindCount == sourceTemplate.mountSummary.bindCount)
            #expect(cloneTemplate.mountSummary.tmpfsCount == sourceTemplate.mountSummary.tmpfsCount)

            try await client.delete(id: cloneID)
            await teardown()
        } catch {
            await teardown()
            throw error
        }
    }

    // MARK: - ③ pull 公开镜像 → 进度事件 > 0

    @Test("③ app pullImage 公开镜像 → 收到进度事件（反向 XPC 进度流真机验证）")
    func pullEmitsProgress() async throws {
        // **绝不动本机镜像状态**（codex R2 P1：删用户镜像、pull 若失败就找不回了；`latest` 可变，
        // 「删了再拉」也不是真还原）。直接 pull——apple/container 对已缓存镜像照样走 manifest 拉取 + 逐层
        // 校验，进度事件仍 > 0，反向 XPC 进度流因此可**无副作用**验证。
        let pullImageRef = "docker.io/library/hello-world:latest"
        let client = LiveContainerRuntimeClient()
        let ref = try #require(ImageRef(pullImageRef))

        var events = 0
        let stream = try await client.pullImage(ref)
        for try await _ in stream { events += 1 }

        #expect(events > 0, "pull 零进度事件——反向进度流没通")
        // 不只「听到一声」——pull 真的完成、镜像落地本机（否则中途断流也能 events>0，
        // T5 folding 的终态处理回归就漏了，altitude P2）。
        #expect((try cli(["image", "inspect", pullImageRef])).code == 0, "pull 后镜像未落地本机")
    }

    // MARK: - ④ delete 不存在的 id → .containerNotFound（真-XPC not-found 契约，R1）

    /// Fake 验不了这条：mock 的错误形状是测试自己编的。**真机**才能验 `get(不存在的 id)` 的真实
    /// 上游错误被 `RuntimeErrorMapper` 映射成 `.containerNotFound`——而**不是**塌缩成 `.operationFailed`
    /// 或超时挂死（R1，plan 风险表 P1：存在性误判）。delete 的前置 `containerExists` 走的正是这条路。
    @Test("④ delete 从未创建的 id → 映射成 .containerNotFound（不塌缩、不挂死）")
    func deleteNonexistentMapsToNotFound() async throws {
        try await sweepLeftovers()

        let client = LiveContainerRuntimeClient()
        let ghost = try #require(ContainerID(uniqueName() + "-ghost"), "ghost id 构造失败")

        await #expect(throws: RuntimeError.containerNotFound(ghost)) {
            try await client.delete(id: ghost)
        }
    }
}
