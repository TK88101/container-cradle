import ContainerCore
import ContainerResource
import ContainerizationError
import Foundation
import TerminalProgress

@testable import ContainerRuntime

/// 上游 client 的替身。**记调用流水**——「回滚有没有真的发生」「幂等短路有没有真的短路」
/// 只能靠它证明，靠断言返回值证明不了。
actor FakeUpstreamClient: UpstreamClient {

    enum Call: Equatable {
        case list
        case get(String)
        case launch(String)
        case stop(String)
        case logs(String)
        case stats(String)
        case listVolumes
        case deleteVolume(String)
        case volumeUsedBytes(String)
        case listImages
        case deleteImage(String)
        case loadedInfraRefs
        case create(String)
        case pull(String)
        case deleteContainer(id: String, force: Bool)
        case cloneCreate(String)
    }

    struct Failure: Error, Equatable {
        let label: String
    }

    private(set) var calls: [Call] = []

    private var snapshots: [String: ContainerSnapshot]
    private var listResult: [ContainerSnapshot]

    /// 按**操作**注入失败——而不是「第 N 次调用失败」。后者会让测试依赖调用顺序，
    /// 加一行无关代码就红，且红得莫名其妙。
    private var failGet: (any Error)?
    private var failList: (any Error)?
    private var failLaunch: (any Error)?
    private var failStop: (any Error)?

    init(snapshots: [ContainerSnapshot] = []) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        self.listResult = snapshots
    }

    func setFailGet(_ error: (any Error)?) { failGet = error }
    func setFailList(_ error: (any Error)?) { failList = error }
    func setFailLaunch(_ error: (any Error)?) { failLaunch = error }
    func setFailStop(_ error: (any Error)?) { failStop = error }
    func setListResult(_ snapshots: [ContainerSnapshot]) { listResult = snapshots }

    func list() async throws -> [ContainerSnapshot] {
        calls.append(.list)

        // 不响应取消的挂死 → 触发 XPCTimeout。
        if hangList {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        if let failList { throw failList }
        return listResult
    }

    private var hangList = false

    /// 让 `list` 永远不回话。用来构造「XPC 超时」这个真实场景。
    func setHangList(_ hang: Bool) { hangList = hang }

    func get(id: String) async throws -> ContainerSnapshot {
        calls.append(.get(id))
        if let failGet { throw failGet }
        // 一旦 deleteContainer 触发（且注入了 recheck 错误），后续 get 抛该错——模拟「delete 后
        // 复核 get 因超时/映射失败而无法确定存在性」（codex P1：这种失败绝不能被当成「已删成功」）。
        if let recheckGetError { throw recheckGetError }
        guard let snapshot = snapshots[id] else {
            // **真上游对不存在的容器抛 `.notFound`**（已核 ContainerClient.swift:112）——Fake 必须忠实
            // 于此，否则「确实不存在」与「get 失败」在 mapper 眼里无从区分（正是 codex P1 要守的边界）。
            throw ContainerizationError(.notFound, message: "fake: 没有这个容器 \(id)")
        }
        return snapshot
    }

    /// deleteContainer 触发后要让复核 get 抛的错（默认 nil）。用于钉「recheck 无法确定存在性 →
    /// 抛原始 delete 错误，绝不谎称删成功」。
    private var getErrorAfterDelete: (any Error)?
    private var recheckGetError: (any Error)?
    func setGetFailsAfterDelete(_ error: (any Error)?) { getErrorAfterDelete = error }

    func launchInitProcess(_ snapshot: ContainerSnapshot) async throws {
        calls.append(.launch(snapshot.id))
        if let failLaunch { throw failLaunch }
    }

    func stop(id: String) async throws {
        calls.append(.stop(id))

        // **不响应取消的挂死**——真实 XPC 对端不回话时就是这样（`Task.sleep` 模拟不出来：
        // 它响应取消，会让一个根本没有超时能力的实现也测出绿灯）。
        //
        // 挂在 `await` 上会让出 actor（actor 在挂起点可重入），所以测试仍读得到 `calls`。
        if hangStop {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        // 模拟优雅停机的耗时（SIGTERM 宽限期）。响应取消没关系——这个注入
        // 测的是「慢但正常的 stop 不该被超时误杀」，不是超时能力本身。
        if let stopDelay {
            try? await Task.sleep(for: stopDelay)
        }

        if let failStop { throw failStop }
    }

    private var hangStop = false
    private var stopDelay: Duration?

    /// 让 `stop` 永远不回话。用来钉死「回滚也必须套超时」（codex review 的 P1）。
    func setHangStop(_ hang: Bool) { hangStop = hang }

    /// 让 `stop` 延迟 `delay` 后才成功（模拟容器吃满 SIGTERM 优雅期才退出）。
    func setStopDelay(_ delay: Duration?) { stopDelay = delay }

    // MARK: - Day 16：create（T6）

    private var failCreate: (any Error)?
    private var hangCreate = false
    private var createResultID: String?

    func setFailCreate(_ error: (any Error)?) { failCreate = error }

    /// 让 `createContainer` 永远不回话——测「create 也套 XPCTimeout，不冻住」。
    func setHangCreate(_ hang: Bool) { hangCreate = hang }

    /// 覆盖 create 返回的 id（默认回 `inputs.id`）。用来测「上游回了个映不回 domain 的 id」。
    func setCreateResultID(_ id: String?) { createResultID = id }

    func createContainer(_ inputs: CreationMapper.CreateInputs) async throws -> String {
        calls.append(.create(inputs.id))

        if hangCreate {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        if let failCreate { throw failCreate }
        return createResultID ?? inputs.id
    }

    // MARK: - Day 16：pull（T6.2）

    private var pullBatches: [[ProgressUpdateEvent]] = []
    private var failPull: (any Error)?
    private var hangPull = false

    /// 脚本化上游反向 XPC 分批投递的进度事件。桥要把它们跨批折叠成累积快照。
    func setPullBatches(_ batches: [[ProgressUpdateEvent]]) { pullBatches = batches }
    func setFailPull(_ error: (any Error)?) { failPull = error }

    /// 让 `pullImage` 永远不回话（投批之前就挂死）——留给「无 blanket 超时、靠取消控制」的探究。
    func setHangPull(_ hang: Bool) { hangPull = hang }

    func pullImage(reference: String, onProgress: @escaping ProgressUpdateHandler) async throws {
        calls.append(.pull(reference))

        if hangPull {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        // 逐批回投——桥要在批与批之间保住累积状态（T2b 回归的靶子）。
        for batch in pullBatches {
            await onProgress(batch)
        }

        if let failPull { throw failPull }
    }

    // MARK: - Day 16：delete（T6.3）

    private var failDelete: (any Error)?
    private var hangDelete = false
    private var removeSnapshotOnDelete = true

    func setFailDelete(_ error: (any Error)?) { failDelete = error }

    /// 让 `deleteContainer` 永远不回话——测「delete 也套 XPCTimeout，不冻住」。
    func setHangDelete(_ hang: Bool) { hangDelete = hang }

    /// 默认成功/尝试删除会把快照移除（复核 get 即报不存在）。设 false 模拟
    /// 「delete 报错且容器仍在」（真失败，复核应报存在）。
    func setRemoveSnapshotOnDelete(_ remove: Bool) { removeSnapshotOnDelete = remove }

    func deleteContainer(id: String, force: Bool) async throws {
        calls.append(.deleteContainer(id: id, force: force))

        if hangDelete {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        // 武装复核 get 的失败（若注入）——让紧接着的复核 get 抛「无法确定存在性」的错。
        recheckGetError = getErrorAfterDelete
        // 先移除再决定成败：模拟「delete 实际删掉了但 XPC 回了个错」（幂等复核的靶子）。
        if removeSnapshotOnDelete { snapshots[id] = nil }

        if let failDelete { throw failDelete }
    }

    // MARK: - Day 16：clone 提交（T6.5）

    private var failCloneCreate: (any Error)?
    private var hangCloneCreate = false
    private var cloneResultID: String?

    /// 供断言 sanitize 结果**透传到上游**（id 改没改、networks 清没清）——只能靠它证，
    /// 断言返回值证不了。
    private(set) var lastCloneConfiguration: ContainerConfiguration?

    func setFailCloneCreate(_ error: (any Error)?) { failCloneCreate = error }
    func setHangCloneCreate(_ hang: Bool) { hangCloneCreate = hang }
    func setCloneResultID(_ id: String?) { cloneResultID = id }

    func createFromConfiguration(_ configuration: ContainerConfiguration) async throws -> String {
        calls.append(.cloneCreate(configuration.id))
        lastCloneConfiguration = configuration

        if hangCloneCreate {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        if let failCloneCreate { throw failCloneCreate }
        return cloneResultID ?? configuration.id
    }

    // MARK: - logs / stats（Day 9 M4）

    private var logsResult: [String: [FileHandle]] = [:]
    private var failLogs: (any Error)?
    private var hangLogs = false

    func setLogsResult(_ id: String, _ handles: [FileHandle]) { logsResult[id] = handles }
    func setFailLogs(_ error: (any Error)?) { failLogs = error }

    /// 让 `logs` 永远不回话。用来钉死「T6' 的 setup 调用也套 XPCTimeout」（codex review P1-7）。
    func setHangLogs(_ hang: Bool) { hangLogs = hang }

    func logs(id: String) async throws -> [FileHandle] {
        calls.append(.logs(id))

        if hangLogs {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        if let failLogs { throw failLogs }
        guard let handles = logsResult[id] else {
            throw Failure(label: "fake: 没有为 \(id) 配置 logs")
        }
        return handles
    }

    private var statsResult: [String: ContainerStats] = [:]
    private var failStats: (any Error)?
    private var hangStats = false

    func setStatsResult(_ id: String, _ stats: ContainerStats) { statsResult[id] = stats }
    func setFailStats(_ error: (any Error)?) { failStats = error }

    /// 让 `stats` 永远不回话——同上，钉死 T10 的 XPCTimeout。
    func setHangStats(_ hang: Bool) { hangStats = hang }

    func stats(id: String) async throws -> ContainerStats {
        calls.append(.stats(id))

        if hangStats {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }

        if let failStats { throw failStats }
        guard let stats = statsResult[id] else {
            throw Failure(label: "fake: 没有为 \(id) 配置 stats")
        }
        return stats
    }

    // MARK: - M5：volume / image（Day 10）

    private var volumeConfigs: [VolumeConfiguration] = []
    private var imageDescriptions: [ImageDescription] = []
    private var failListVolumes: (any Error)?
    private var failDeleteVolume: (any Error)?
    private var failListImages: (any Error)?
    private var failDeleteImage: (any Error)?

    func setVolumes(_ configs: [VolumeConfiguration]) { volumeConfigs = configs }
    func setImages(_ descriptions: [ImageDescription]) { imageDescriptions = descriptions }
    func setFailListVolumes(_ error: (any Error)?) { failListVolumes = error }
    func setFailDeleteVolume(_ error: (any Error)?) { failDeleteVolume = error }
    func setFailListImages(_ error: (any Error)?) { failListImages = error }
    func setFailDeleteImage(_ error: (any Error)?) { failDeleteImage = error }

    func listVolumes() async throws -> [VolumeConfiguration] {
        calls.append(.listVolumes)
        if let failListVolumes { throw failListVolumes }
        return volumeConfigs
    }

    func deleteVolume(name: String) async throws {
        calls.append(.deleteVolume(name))
        if let failDeleteVolume { throw failDeleteVolume }
        volumeConfigs.removeAll { $0.name == name }
    }

    // MARK: usage（enrichment 的三种命运：值 / 失败 / 门后挂起）

    private var usageValues: [String: UInt64] = [:]
    private var usageFailures: Set<String> = []
    private var usageGatedNames: Set<String> = []
    private var gatedUsage: [(name: String, continuation: UnsafeContinuation<UInt64, any Error>)] = []

    /// 观测点：启动过多少次（★R5 闭门断言）与并发峰值（★R1 限流断言）。
    private(set) var usageStartedCount = 0
    private var usageInFlight = 0
    private(set) var usagePeakConcurrency = 0

    func setUsage(_ name: String, bytes: UInt64) { usageValues[name] = bytes }
    func setUsageFails(_ name: String) { usageFailures.insert(name) }

    /// 让 `name` 的 usage 调用**停在门后**（不响应取消的挂起，同 hangStop 的理由）。
    /// 之后可用 `releaseGatedUsage` 放行——或永不放行（预算 no-wait 的测法）。
    func setUsageGated(_ name: String) { usageGatedNames.insert(name) }

    /// 放行第一个门后的 `name` 调用。返回是否真的放了一个。
    @discardableResult
    func releaseGatedUsage(_ name: String, bytes: UInt64) -> Bool {
        guard let index = gatedUsage.firstIndex(where: { $0.name == name }) else { return false }
        let entry = gatedUsage.remove(at: index)
        entry.continuation.resume(returning: bytes)
        return true
    }

    func volumeUsedBytes(name: String) async throws -> UInt64 {
        calls.append(.volumeUsedBytes(name))
        usageStartedCount += 1
        usageInFlight += 1
        usagePeakConcurrency = max(usagePeakConcurrency, usageInFlight)
        defer { usageInFlight -= 1 }

        if usageGatedNames.contains(name) {
            return try await withUnsafeThrowingContinuation { continuation in
                gatedUsage.append((name, continuation))
            }
        }
        if usageFailures.contains(name) {
            throw Failure(label: "fake: usage(\(name)) 注定失败")
        }
        guard let bytes = usageValues[name] else {
            throw Failure(label: "fake: 没有为 \(name) 配置 usage")
        }
        return bytes
    }

    func listImages() async throws -> [ImageDescription] {
        calls.append(.listImages)
        if let failListImages { throw failListImages }
        return imageDescriptions
    }

    func deleteImage(reference: String) async throws {
        calls.append(.deleteImage(reference))
        if let failDeleteImage { throw failDeleteImage }
        imageDescriptions.removeAll { $0.reference == reference }
    }

    // MARK: infra 过滤

    private var loadedInfra: Result<Set<String>, any Error> = .success([])

    func setLoadedInfraRefs(_ refs: Set<String>) { loadedInfra = .success(refs) }
    func setLoadedInfraFails() { loadedInfra = .failure(Failure(label: "fake: config 加载失败")) }

    func loadedInfraImageReferences() async throws -> Set<String> {
        calls.append(.loadedInfraRefs)
        return try loadedInfra.get()
    }

    /// protocol 的这条是 **sync**（stock 默认构造零 XPC、不会失败）——actor 满足 sync
    /// 协议要求只能用 `nonisolated`。`nonisolated(unsafe)` 的前提：测试只在 setup 阶段
    /// 写一次、之后只读，不存在真实竞争。
    nonisolated(unsafe) private var stockInfraRefs: Set<String> = []

    nonisolated func stockInfraImageReferences() -> Set<String> {
        stockInfraRefs
    }

    func setStockInfraRefs(_ refs: Set<String>) { stockInfraRefs = refs }
}

/// 宿主路径存在性的替身。**默认「什么都不存在」**——
/// 默认值必须指向让 R13 那条路径**被走到**的方向。默认「都存在」的话，
/// mount 校验的测试就要显式 opt-in，而忘了 opt-in 的那条测试会静默地绕过校验。
struct FakePathChecker: PathChecker {
    let existing: Set<String>

    init(existing: Set<String> = []) {
        self.existing = existing
    }

    func fileExists(atPath path: String) -> Bool {
        existing.contains(path)
    }
}

/// 进程表探测的替身。运行时死活的**唯一权威**（R14）——错误映射要问它。
struct FakeRuntimeProber: RuntimeProber {
    let result: ProbeResult

    static let up = FakeRuntimeProber(
        result: .running(RuntimeGeneration(pid: 1234, startTime: 5678))
    )
    static let down = FakeRuntimeProber(result: .down)

    func probe() async -> ProbeResult { result }
}
