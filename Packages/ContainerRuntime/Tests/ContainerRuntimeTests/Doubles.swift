import ContainerCore
import ContainerResource
import Foundation

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
        guard let snapshot = snapshots[id] else {
            throw Failure(label: "fake: 没有这个容器 \(id)")
        }
        return snapshot
    }

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

        if let failStop { throw failStop }
    }

    private var hangStop = false

    /// 让 `stop` 永远不回话。用来钉死「回滚也必须套超时」（codex review 的 P1）。
    func setHangStop(_ hang: Bool) { hangStop = hang }

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
