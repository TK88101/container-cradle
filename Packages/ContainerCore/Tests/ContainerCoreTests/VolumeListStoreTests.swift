import Foundation
import Testing

@testable import ContainerCore

/// 一个**可以精确控制返回时机**的 volume 运行时，只用来测「跨过 await 之后世界变了」
/// 这类竞态——同 `ContainerListStoreTests` 的 `GatedRuntimeClient`，但多 gate 了
/// `inspectVolume`（用来验证 in-flight 期间 `cancelDeletion` 必须是 no-op）。
///
/// `deleteVolume` 刻意**不** gate：resurrect 向量测的是「删除成功触发的刷新」与
/// 「在途旧刷新」之间的竞态，不是删除本身的时机——gate 太多东西会让测试的因果链
/// 变得难以推理，且这条路径已经被 fingerprint / targetChanged 的测试覆盖过了。
private actor GatedVolumeRuntimeClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private var pendingListVolumes: [CheckedContinuation<[Volume], Never>] = []
    private var pendingInspect: [CheckedContinuation<Volume?, Never>] = []
    private var volumes: [Volume]

    var pendingListVolumesCount: Int { pendingListVolumes.count }
    var pendingInspectCount: Int { pendingInspect.count }

    init(volumes: [Volume]) {
        self.volumes = volumes
    }

    func listVolumes() async throws(RuntimeError) -> [Volume] {
        await withCheckedContinuation { continuation in
            pendingListVolumes.append(continuation)
        }
    }

    /// 放行第 `index` 次发起的 `listVolumes` 调用（0 起）。
    func completeListVolumes(_ index: Int, with volumes: [Volume]) {
        pendingListVolumes[index].resume(returning: volumes)
    }

    func inspectVolume(named name: String) async throws(RuntimeError) -> Volume? {
        await withCheckedContinuation { continuation in
            pendingInspect.append(continuation)
        }
    }

    /// 放行第 `index` 次发起的 `inspectVolume` 调用（0 起）。
    func completeInspect(_ index: Int, with volume: Volume?) {
        pendingInspect[index].resume(returning: volume)
    }

    func deleteVolume(_ target: Volume) throws(RuntimeError) {
        volumes.removeAll(where: { $0.name == target.name })
    }

    // M5 volume 测试无消费者的方法：显式 stub（同 `GatedRuntimeClient` 的纪律——
    // 不给 protocol 默认实现，漏实现必须编译红）。
    func list() throws(RuntimeError) -> [Container] { [] }
    func start(id: ContainerID) throws(RuntimeError) {}
    func stop(id: ContainerID) throws(RuntimeError) {}
    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample { ContainerStatsSample() }
    func listImages() throws(RuntimeError) -> ImageListSnapshot {
        ImageListSnapshot(images: [], isInfraFilterAuthoritative: true)
    }
    func deleteImage(reference: ImageRef) throws(RuntimeError) {}
}

@MainActor
@Suite("VolumeListStore：单飞刷新 + 删除状态机（fingerprint 复核是 R7 主防线）")
struct VolumeListStoreTests {

    static func volume(
        _ name: String,
        creationDate: Date = Date(timeIntervalSince1970: 0),
        source: String? = nil
    ) -> Volume {
        Volume(
            name: name,
            creationDate: creationDate,
            source: source ?? "/var/lib/containers/volumes/\(name)",
            sizeMaxBytes: nil,
            usedBytes: nil
        )
    }

    /// 等到 client 手上攒够 `count` 个未返回的 `listVolumes` 调用。
    /// 用 `Task.yield()` 轮询：同 `ContainerListStoreTests`，协作式调度下确定会推进。
    private static func waitForPendingListVolumes(_ count: Int, on client: GatedVolumeRuntimeClient) async {
        for _ in 0..<10_000 {
            if await client.pendingListVolumesCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 listVolumes 请求")
    }

    private static func waitForPendingInspect(_ count: Int, on client: GatedVolumeRuntimeClient) async {
        for _ in 0..<10_000 {
            if await client.pendingInspectCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 inspectVolume 请求")
    }

    // MARK: - 刷新单飞

    @Test("刷新单飞：慢刷新期间再刷，只落最后一次")
    func staleRefreshDoesNotOverwriteNewer() async {
        let client = GatedVolumeRuntimeClient(volumes: [])
        let store = VolumeListStore(client: client)

        let first = Task { await store.refresh() }
        await Self.waitForPendingListVolumes(1, on: client)

        let second = Task { await store.refresh() }
        await Self.waitForPendingListVolumes(2, on: client)

        // 后发起的先返回。
        await client.completeListVolumes(1, with: [Self.volume("new")])
        // 先发起的后返回——它已经被取代了，不该再写回。
        await client.completeListVolumes(0, with: [Self.volume("stale")])

        await first.value
        await second.value

        guard case .loaded(let volumes) = store.state else {
            Issue.record("期望 loaded，实际 \(store.state)")
            return
        }
        #expect(volumes.map(\.name) == ["new"])
    }

    // MARK: - 基础状态

    @Test("初始是 loading，deletionFlow 是 idle")
    func startsLoadingAndIdle() {
        let store = VolumeListStore(client: FakeContainerRuntimeClient(containers: []))
        guard case .loading = store.state else {
            Issue.record("期望 loading，实际 \(store.state)")
            return
        }
        #expect(store.deletionFlow == .idle)
    }

    @Test("刷新成功 → loaded")
    func refreshLoads() async {
        let client = FakeContainerRuntimeClient(containers: [], volumes: [Self.volume("data")])
        let store = VolumeListStore(client: client)

        await store.refresh()

        guard case .loaded(let volumes) = store.state else {
            Issue.record("期望 loaded，实际 \(store.state)")
            return
        }
        #expect(volumes.map(\.name) == ["data"])
    }

    @Test("刷新失败 → failed，带着上一次快照")
    func refreshFailureKeepsLastKnownSnapshot() async {
        let client = FakeContainerRuntimeClient(containers: [], volumes: [Self.volume("data")])
        let store = VolumeListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .listVolumes)
        await store.refresh()

        guard case .failed(let error, let lastKnown) = store.state else {
            Issue.record("期望 failed，实际 \(store.state)")
            return
        }
        #expect(error == .runtimeUnavailable)
        #expect(lastKnown.map(\.name) == ["data"])
        #expect(store.displayedVolumes.map(\.name) == ["data"])
    }

    // MARK: - beginDeletion / cancelDeletion 守卫

    @Test("beginDeletion：idle → confirming")
    func beginDeletionFromIdle() {
        let target = Self.volume("doomed")
        let store = VolumeListStore(client: FakeContainerRuntimeClient(containers: [], volumes: [target]))

        store.beginDeletion(of: target)

        #expect(store.deletionFlow == .confirming(target: target))
    }

    @Test("beginDeletion：confirming 态里换靶不生效（仅 idle/failed/targetChanged 可进入 confirming）")
    func beginDeletionDoesNotSwitchTargetWhileConfirming() {
        let target = Self.volume("first")
        let other = Self.volume("second")
        let client = FakeContainerRuntimeClient(containers: [], volumes: [target, other])
        let store = VolumeListStore(client: client)

        store.beginDeletion(of: target)
        store.beginDeletion(of: other)

        #expect(store.deletionFlow == .confirming(target: target))
    }

    @Test("cancelDeletion：idle 态调用是 no-op")
    func cancelDeletionNoOpFromIdle() {
        let store = VolumeListStore(client: FakeContainerRuntimeClient(containers: []))

        store.cancelDeletion()

        #expect(store.deletionFlow == .idle)
    }

    @Test("cancelDeletion：confirming → idle")
    func cancelDeletionFromConfirming() {
        let target = Self.volume("doomed")
        let store = VolumeListStore(client: FakeContainerRuntimeClient(containers: [], volumes: [target]))

        store.beginDeletion(of: target)
        store.cancelDeletion()

        #expect(store.deletionFlow == .idle)
    }

    @Test("verifying 中 cancelDeletion 是 no-op（in-flight 由 UI 禁用，store 也要 guard）")
    func cancelDeletionNoOpDuringVerifying() async {
        let target = Self.volume("in-flight")
        let client = GatedVolumeRuntimeClient(volumes: [target])
        let store = VolumeListStore(client: client)

        store.beginDeletion(of: target)
        let confirmTask = Task { await store.confirmDeletion(typed: target.name) }
        await Self.waitForPendingInspect(1, on: client)

        #expect(store.deletionFlow == .verifying(target: target))

        store.cancelDeletion()
        #expect(store.deletionFlow == .verifying(target: target))

        // 复核通过 → deleting → delete（同步）→ 成功后自动 refresh()，
        // 而 refresh() 里的 listVolumes() 也被 gate 住——不放行就永远等不到
        // confirmTask 收工（这正是本仓库「await 是窗口」血训的一次活体示范）。
        await client.completeInspect(0, with: target)
        await Self.waitForPendingListVolumes(1, on: client)
        await client.completeListVolumes(0, with: [])
        await confirmTask.value

        #expect(store.deletionFlow == .idle)
    }

    // MARK: - canConfirm 边界

    @Test("canConfirm 边界：精确匹配放行，大小写/错字拒绝，首尾换行容忍，非 confirming 恒 false")
    func canConfirmBoundaries() {
        let target = Self.volume("precise-name")
        let store = VolumeListStore(client: FakeContainerRuntimeClient(containers: [], volumes: [target]))

        // 非 confirming 态（idle）：恒 false。
        #expect(!store.canConfirm(typed: "precise-name"))

        store.beginDeletion(of: target)
        #expect(store.canConfirm(typed: "precise-name"))
        #expect(!store.canConfirm(typed: "Precise-Name"))
        #expect(!store.canConfirm(typed: "precise-nam"))
        #expect(store.canConfirm(typed: "precise-name\n"))
    }

    // MARK: - confirmDeletion：核心状态机

    @Test("typed 不匹配 → confirmDeletion 是 no-op：状态仍 confirming，零删除调用")
    func confirmDeletionNoOpOnMismatch() async {
        let target = Self.volume("guarded")
        let client = FakeContainerRuntimeClient(containers: [], volumes: [target])
        let store = VolumeListStore(client: client)

        store.beginDeletion(of: target)
        await store.confirmDeletion(typed: "wrong-name")

        #expect(store.deletionFlow == .confirming(target: target))
        let calls = await client.calls
        #expect(calls.isEmpty)
    }

    /// ★R1 主防线：确认框开着的几十秒里，同名卷可能被外部删除重建。
    /// 这里用「target 与实际卷 creationDate 不同」模拟——store 拿着的是确认时那份陈旧快照。
    @Test("fingerprint 复核不匹配（同名卷但 creationDate 不同）→ targetChanged，删除调用为零")
    func confirmDeletionDetectsIdentityMismatch() async {
        let actualVolume = Self.volume("recreated", creationDate: Date(timeIntervalSince1970: 100))
        let staleTarget = Self.volume("recreated", creationDate: Date(timeIntervalSince1970: 0))

        let client = FakeContainerRuntimeClient(containers: [], volumes: [actualVolume])
        let store = VolumeListStore(client: client)

        store.beginDeletion(of: staleTarget)
        await store.confirmDeletion(typed: staleTarget.name)

        guard case .targetChanged(let changed) = store.deletionFlow else {
            Issue.record("期望 targetChanged，实际 \(store.deletionFlow)")
            return
        }
        #expect(changed == staleTarget)

        let calls = await client.calls
        #expect(!calls.contains(.deleteVolume(staleTarget.name)))
    }

    @Test("复核时卷已消失（inspect 返回 nil）→ targetChanged，删除调用为零")
    func confirmDeletionTargetVanished() async {
        let target = Self.volume("ghost")
        let client = FakeContainerRuntimeClient(containers: [], volumes: [])
        let store = VolumeListStore(client: client)

        store.beginDeletion(of: target)
        await store.confirmDeletion(typed: target.name)

        guard case .targetChanged(let changed) = store.deletionFlow else {
            Issue.record("期望 targetChanged，实际 \(store.deletionFlow)")
            return
        }
        #expect(changed == target)

        let calls = await client.calls
        #expect(!calls.contains(.deleteVolume(target.name)))
    }

    /// ★R2 断言在这条用例里做：复核走的是 `inspectVolume`，不是带 usage enrichment 的
    /// `listVolumes()`——断言整段 calls 序列，中间不许混进第二次 `listVolumes`
    /// （除了删除成功之后那次事后刷新）。
    @Test("删除成功 → idle，展示列表不含该卷；复核路径 identity-only（verifying 期间零 listVolumes）")
    func confirmDeletionSucceeds() async {
        let target = Self.volume("doomed")
        let client = FakeContainerRuntimeClient(containers: [], volumes: [target])
        let store = VolumeListStore(client: client)

        await store.refresh()
        store.beginDeletion(of: target)
        #expect(store.canConfirm(typed: target.name))

        await store.confirmDeletion(typed: target.name)

        #expect(store.deletionFlow == .idle)
        #expect(store.displayedVolumes.isEmpty)

        let calls = await client.calls
        #expect(calls == [.listVolumes, .inspectVolume(target.name), .deleteVolume(target.name), .listVolumes])
    }

    @Test("delete 失败 → failed 携带 reason；可 cancelDeletion 回 idle；可 beginDeletion 重试")
    func confirmDeletionFailureAllowsCancelAndRetry() async {
        let target = Self.volume("stubborn")
        let client = FakeContainerRuntimeClient(containers: [], volumes: [target])
        await client.inject(.operationFailed(reason: "volume in use"), for: .deleteVolume)
        let store = VolumeListStore(client: client)

        store.beginDeletion(of: target)
        await store.confirmDeletion(typed: target.name)

        guard case .failed(let failedTarget, let reason) = store.deletionFlow else {
            Issue.record("期望 failed，实际 \(store.deletionFlow)")
            return
        }
        #expect(failedTarget == target)
        #expect(reason.contains("volume in use"))

        store.cancelDeletion()
        #expect(store.deletionFlow == .idle)

        store.beginDeletion(of: target)
        #expect(store.deletionFlow == .confirming(target: target))
    }

    /// codex 裁决 5：删除成功后的刷新可能与一次在途旧刷新交错——旧刷新若后写回，
    /// 会让已删的卷在 UI 上「复活」。断言的是**最终快照**这个不变式，不是时序。
    @Test("resurrect 向量：删除成功触发的刷新与在途旧刷新交错，最终快照不含已删卷")
    func resurrectVectorDoesNotBringBackDeletedVolume() async {
        let target = Self.volume("doomed")
        let client = GatedVolumeRuntimeClient(volumes: [target])
        let store = VolumeListStore(client: client)

        // 在途旧刷新：手动发起，先卡住。
        let staleRefresh = Task { await store.refresh() }
        await Self.waitForPendingListVolumes(1, on: client)

        // 删除流程：confirming → verifying（inspect 被 gate）。
        store.beginDeletion(of: target)
        let confirmTask = Task { await store.confirmDeletion(typed: target.name) }
        await Self.waitForPendingInspect(1, on: client)
        // 复核通过 → deleting → delete（同步）→ 触发新的、也被 gate 的 refresh。
        await client.completeInspect(0, with: target)
        await Self.waitForPendingListVolumes(2, on: client)

        // 旧刷新后返回，但快照里还带着已删的卷（模拟慢响应携带过期数据）。
        await client.completeListVolumes(0, with: [target])
        // 新刷新后返回，是真实的、不含已删卷的快照——它必须是最终生效的那份。
        await client.completeListVolumes(1, with: [])

        await staleRefresh.value
        await confirmTask.value

        #expect(store.displayedVolumes.isEmpty)
        #expect(store.deletionFlow == .idle)
    }
}
