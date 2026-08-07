import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import Foundation
import Logging
import SystemPackage
import TerminalProgress

/// 上游 `ContainerClient` 的可替身化包装。**只在本 package 内可见。**
///
/// ## 这不违反 D1，尽管签名里有 `ContainerSnapshot`
///
/// PLAN 说过「不要给 `ContainerClient` 做 protocol wrapper——那样 protocol 里会出现
/// `ContainerSnapshot`，上游类型立刻渗透进 test 和 UI」。那条理由在**这里不成立**：
///
/// - UI 住在另一个 package（app target 只链 `ContainerCore`），够不着这个 `internal` protocol；
/// - 用它的测试是 `ContainerRuntimeTests`，本来就链上游。
///
/// D1 要挡的是「上游类型漏进 domain / supervisor / UI」，不是「本 package 内部不许提上游类型」——
/// 后者做不到（mapper 总得看见上游的字段）。
///
/// ## 不做的代价是零测试
///
/// `ContainerClient` 是 concrete struct，不可替身。不抽这一层，`LiveContainerRuntimeClient`
/// 的整段序列——幂等短路、**mount 源校验**、失败回滚、错误映射——**一行测试都跑不了**。
/// 而 R13 的生死线正好在里面。
///
/// 「不好测」不等于「不用测」：`LibprocProcessTable` 被豁免过一次，结果里面藏着一个
/// 「只扫 1/4 进程」的 P1（CLAUDE.md）。**被豁免的那一层最容易藏 P1。**
protocol UpstreamClient: Sendable {

    func list() async throws -> [ContainerSnapshot]

    func get(id: String) async throws -> ContainerSnapshot

    /// 起 init 进程：`ProcessIO.create` → `bootstrap` → `start` → `closeAfterStart` 一整段。
    ///
    /// **刻意把这四步捆成一个方法**，而不是让 protocol 暴露 `ProcessIO` / `ClientProcess`：
    /// 那两个类型替身起来要连 `Terminal.Size`、`FileHandle` 一起造，而它们之间**没有任何判断**——
    /// 全是直线调用。把它们留在 adapter 里（真正拿不到确定性输入的部分才该豁免），
    /// 判断力（短路 / 校验 / 回滚）全部留在可测的 `LiveContainerRuntimeClient` 里。
    func launchInitProcess(_ snapshot: ContainerSnapshot) async throws

    func stop(id: String) async throws

    /// create（T6）：CLI 同源装配 `Utility.containerConfigFromFlags` → `client.create`，返回新容器 id。
    /// **全 straight-line、无判断**——spec→inputs 的映射由纯 `CreationMapper` 做（已测），
    /// 错误映射 / XPCTimeout 在上层 `LiveContainerRuntimeClient`。这一层只把「装配 + create」捆成一步。
    func createContainer(_ inputs: CreationMapper.CreateInputs) async throws -> String

    /// pull（T6.2）：`ClientImage.pull` 的直线转发，进度经 `onProgress` **反向 XPC** 回投。
    /// **跨批折叠/累积是判断**（T2b「字节假 0」的高发地：只数 set* 漏掉跨批 add*），它住可测的
    /// `LiveContainerRuntimeClient`，不埋在这层。这层只把「装配 systemConfig + pull」捆成一步。
    /// 无返回值：domain `pullImage` 要的是进度流，pull 出的 `ClientImage` 用不上，终点返回即成功。
    func pullImage(reference: String, onProgress: @escaping ProgressUpdateHandler) async throws

    /// delete（T6.3）：`ContainerClient.delete(id:force:)` 的直线转发。**force 恒 true**由上层定
    /// （删 running 走 server SIGKILL+cleanup）。not-found / runtime-down 的**判断**——前置复核、
    /// 报错后是否复核——全在可测的 `LiveContainerRuntimeClient`（§3.4 / codex #12），不在这层。
    func deleteContainer(id: String, force: Bool) async throws

    /// clone 提交（T6.5）：用**已 sanitize 的**源 configuration 直接 create，返回新容器 id。
    /// **不复用 fresh 的 `containerConfigFromFlags`**——那会重装一套 `Flags.*` 并重 fetch 镜像；
    /// clone 复用源 configuration，只需补一个 host 级 `Kernel`（与容器无关，`getDefaultKernel` 直接取）。
    /// sanitize（判断，codex #3）在纯 `CreationMapper.sanitizeForClone`（已测），这层只装配 + create。
    func createFromConfiguration(_ configuration: ContainerConfiguration) async throws -> String

    /// `fhs[0]` = stdio，`fhs[1]` = boot log（已核实源码：`ContainerClient.swift:266`）。
    /// **哪个用哪个不用，是 `LiveContainerRuntimeClient` 的事**——这一层只负责转发。
    func logs(id: String) async throws -> [FileHandle]

    /// 单发一次 = 一个瞬时计数器快照。CPU% 需要相邻两次样本才能算出速率，
    /// 那是 core `StatsCollector` 的事，不是这一层的事。
    func stats(id: String) async throws -> ContainerStats

    // MARK: - M5：volume / image（Day 10）

    func listVolumes() async throws -> [VolumeConfiguration]

    func deleteVolume(name: String) async throws

    /// 单卷真实分配字节（server 端递归 `totalFileAllocatedSize`）。大卷可能扫很久——
    /// 调用方必须套 per-call XPCTimeout **并**做全局预算（`VolumeUsageCollector`）。
    func volumeUsedBytes(name: String) async throws -> UInt64

    func listImages() async throws -> [ImageDescription]

    /// `garbageCollect` 固定 false——与官方 CLI `image rm` 同口径（`ImageDelete.swift:72`）。
    func deleteImage(reference: String) async throws

    /// **真实加载** config → infra 引用集合（builder + vminit）。加载失败就抛——
    /// 「失败之后用什么兜底」是判断，判断住可测的 `LiveContainerRuntimeClient`，
    /// 不埋在这个不可测的 adapter 里。
    func loadedInfraImageReferences() async throws -> Set<String>

    /// stock 默认 infra 引用（`ContainerSystemConfig()` 默认构造：零 XPC、不会失败）。
    /// fallback 专用——值由上游维护、随 exact pin 走，不是我们硬编码（D-C：
    /// 硬编码会在上游改名那天无声失效，R14 同款病）。
    func stockInfraImageReferences() -> Set<String>
}

/// 真正打 XPC 的那一层。**一个 `if` 都没有**——判断力全在上层。
///
/// 这是本 package 唯一的覆盖率豁免项，理由是它拿不到确定性输入（需要真 apiserver）。
/// 豁免的边界就到这里为止：它上面每一个分支都必须被测。
///
/// ## ★★★ 连接**绝不跨代**（Day 7 的 M3 验收红了才挖出来的 P0）
///
/// 第一版写的是 `private let client = ContainerClient()`——App 启动时建一次、之后一直复用。
/// 它在 M3 真机验收里死得干干净净：
///
/// - 上游 `ContainerClient.init()` 建**一条** `XPCClient`，而 `XPCClient.init` 建**一条**
///   mach service 连接就 activate，事件处理器是 `xpc_connection_set_event_handler { _ in }`
///   ——**连接失效被彻底忽略**（已读上游源码核实：`ContainerXPC/XPCClient.swift:34`）。
/// - `container system stop` 把那个 launchd service 卸掉，这条连接随之 **INVALID**。
///   xpc 的 invalid 是**终态**：不自愈、不重连。
/// - 于是运行时回来后，App 手里攥着一条死连接：`list()` 全失败（界面报
///   "failed to list containers"），reconcile 连败 5 次 → **熔断**。
///
/// **这个 App 存在的唯一理由就是熬过 apiserver 重启，而它的客户端恰恰熬不过。**
/// 官方 CLI 从没暴露这个问题：它每次调用都是新进程、新连接。
///
/// 修法不是「失败了再重连」（那要靠在每个调用点记得判断），而是**让连接根本活不到下一代**：
/// 每次调用现建现用。代价是每次多一次 `xpc_connection_create_mach_service`
/// （实测一次完整 `start()` 端到端 0.49 秒，建连接淹没在噪声里）；
/// 换来的是「客户端记住了上一代的连接」这件事**写不出来**。
///
/// 这是 D3 的同一条纪律换了个位置：**跨过运行时换代，得重新证明自己连的是活着的那一个。**
struct LiveUpstreamClient: UpstreamClient {

    /// **每次都是新的。** 见上：旧连接在运行时换代后是终态失效的死连接。
    private var client: ContainerClient { ContainerClient() }

    /// create adapter 的 `containerConfigFromFlags` 要一个 `Logger`。GUI 无终端，label 只用于上游内部诊断。
    private static let log = Logger(label: "cof.container-runtime")

    func list() async throws -> [ContainerSnapshot] {
        try await client.list()
    }

    func get(id: String) async throws -> ContainerSnapshot {
        try await client.get(id: id)
    }

    func launchInitProcess(_ snapshot: ContainerSnapshot) async throws {
        // 整段序列共用**同一个**新建的 client：`bootstrap` 返回的 `ClientProcess`
        // 得靠它背后那条连接活着才 `start()` 得起来。
        let client = self.client

        // detach = true：我们是常驻 supervisor，不是终端前台。
        let io = try ProcessIO.create(
            tty: snapshot.configuration.initProcess.terminal,
            interactive: false,
            detach: true
        )
        defer { try? io.close() }

        // `dynamicEnv` 传空。官方 CLI 在这里透传宿主的 `SSH_AUTH_SOCK`——**我们不能照抄**：
        // 那是「把自己进程的 env 注入容器」，而我们的 env 里有什么由用户的启动环境决定，
        // 不由我们决定（PLAN 依赖策略：子进程 env 白名单，绝不透传我们的 env）。
        let process = try await client.bootstrap(id: snapshot.id, stdio: io.stdio, dynamicEnv: [:])
        try await process.start()
        try io.closeAfterStart()
    }

    func stop(id: String) async throws {
        try await client.stop(id: id)
    }

    func createContainer(_ inputs: CreationMapper.CreateInputs) async throws -> String {
        // 整段序列共用**同一个**新建的 client（连接不跨代，见类型注释）。
        let client = self.client
        let systemConfig = try await Self.loadSystemConfig()

        // CLI 同源装配：唯一可行路径（Kernel 无其他 public 获取途径，spike V2 已核）。
        // progressUpdate 传空——create 是一次性建停机容器，进度是 pull 的事（T5 走另一条）。
        let (config, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: inputs.id,
            image: inputs.image,
            arguments: inputs.arguments,
            process: inputs.process,
            management: inputs.management,
            resource: inputs.resource,
            registry: inputs.registry,
            imageFetch: inputs.imageFetch,
            containerSystemConfig: systemConfig,
            progressUpdate: { _ in },
            log: Self.log
        )
        try await client.create(configuration: config, kernel: kernel, initImage: initImage)
        return inputs.id
    }

    func pullImage(reference: String, onProgress: @escaping ProgressUpdateHandler) async throws {
        // `ClientImage.pull` 自建 XPCClient（M5 同款 static func，连接不跨代由上游保证）。
        // 需 systemConfig 做 reference 归一化 + scheme/dns 解析——与 create/infra 共用同一装载。
        let systemConfig = try await Self.loadSystemConfig()
        _ = try await ClientImage.pull(
            reference: reference,
            containerSystemConfig: systemConfig,
            progressUpdate: onProgress
        )
    }

    func deleteContainer(id: String, force: Bool) async throws {
        try await client.delete(id: id, force: force)
    }

    func createFromConfiguration(_ configuration: ContainerConfiguration) async throws -> String {
        let client = self.client
        // host 级默认 kernel（arch 匹配、与具体容器无关）——比重跑 containerConfigFromFlags 干净得多。
        let kernel = try await ClientKernel.getDefaultKernel(for: SystemPlatform.current)
        // initImage: nil → 上游用默认 vminit（同 fresh 路径 `management.initImage` 默认 nil）。
        try await client.create(configuration: configuration, kernel: kernel, initImage: nil)
        return configuration.id
    }

    func logs(id: String) async throws -> [FileHandle] {
        try await client.logs(id: id)
    }

    func stats(id: String) async throws -> ContainerStats {
        try await client.stats(id: id)
    }

    // MARK: - M5：volume / image（Day 10）
    //
    // `ClientVolume` / `ClientImage` / `ClientDiskUsage` 全是 static func、
    // **每次调用新建 XPCClient**（已读上游源码，Spikes/SPIKE-RESULT-DAY10.md §4）——
    // 「连接绝不跨代」在这几条路径上是上游自带的，不需要我们做什么。

    func listVolumes() async throws -> [VolumeConfiguration] {
        try await ClientVolume.list()
    }

    func deleteVolume(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }

    func volumeUsedBytes(name: String) async throws -> UInt64 {
        try await ClientVolume.volumeDiskUsage(name: name)
    }

    func listImages() async throws -> [ImageDescription] {
        try await ClientImage.list().map(\.description)
    }

    func deleteImage(reference: String) async throws {
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }

    func loadedInfraImageReferences() async throws -> Set<String> {
        let config = try await Self.loadSystemConfig()
        return [config.build.image, config.vminit.image]
    }

    /// 加载 daemon 报告的 `ContainerSystemConfig`。**create（T6）与 infra 过滤（M5）共用**——
    /// 两条路都需要它，单一来源避免装配漂移。
    ///
    /// CLI 同源（`Application.loadContainerSystemConfig`）：ping 拿 **daemon 报告的** appRoot/installRoot，
    /// 再读那两处 TOML。**刻意不用** `ConfigurationLoader.load()` 的零参默认（env 驱动的路径解析）：
    /// 我们是 GUI，用户自定义 root 时那些 env 不会传给我们——零参版本会去读**默认**位置、读不到自定义
    /// config、返回 stock 默认值，然后**自称权威**——自定义的 vminit 就这么被暴露给删除（V3 的原样灾难）。
    /// ping 走 XPC 问 daemon，与我们进程的 env 无关。
    private static func loadSystemConfig() async throws -> ContainerSystemConfig {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        return try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(
                    in: FilePath(health.appRoot.path(percentEncoded: false)),
                    of: .appRoot
                ),
                ConfigurationLoader.configurationFile(
                    in: FilePath(health.installRoot.path(percentEncoded: false)),
                    of: .installRoot
                ),
            ]
        )
    }

    func stockInfraImageReferences() -> Set<String> {
        let defaults = ContainerSystemConfig()
        return [defaults.build.image, defaults.vminit.image]
    }
}

/// 宿主路径存在性检查。抽成 protocol 只为一件事：**让 mount 校验可测**（R13）。
protocol PathChecker: Sendable {
    func fileExists(atPath path: String) -> Bool
}

struct FileSystemPathChecker: PathChecker {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
