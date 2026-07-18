import Foundation
import Testing

@testable import ContainerCore

/// 可以把 `stop` / `start` 悬在半空的运行时——拒绝制的测试必须让第一个动作
/// 停在 in-flight 态，才能观察「第二个动作被拒且上游计数不变」。
/// 套路同 `VolumeListStoreTests.GatedVolumeRuntimeClient`。
private actor GatedActionRuntimeClient: ContainerRuntimeClient {

    private var pendingStops: [CheckedContinuation<Void, Never>] = []
    private var pendingStarts: [CheckedContinuation<Void, Never>] = []

    /// 上游收到过的调用数（含挂起中的）——拒绝制断言的就是这两个数。
    private(set) var stopCallCount = 0
    private(set) var startCallCount = 0

    var pendingStopCount: Int { pendingStops.count }
    var pendingStartCount: Int { pendingStarts.count }

    func stop(id: ContainerID) async throws(RuntimeError) {
        stopCallCount += 1
        await withCheckedContinuation { pendingStops.append($0) }
    }

    func start(id: ContainerID) async throws(RuntimeError) {
        startCallCount += 1
        await withCheckedContinuation { pendingStarts.append($0) }
    }

    /// 放行第 `index` 次发起的 `stop`（0 起）。
    func completeStop(_ index: Int) {
        pendingStops[index].resume()
    }

    /// 放行第 `index` 次发起的 `start`（0 起）。
    func completeStart(_ index: Int) {
        pendingStarts[index].resume()
    }

    // 本测试无消费者的方法：显式 stub（纪律同 `GatedVolumeRuntimeClient`——
    // 不给 protocol 默认实现，漏实现必须编译红）。
    func list() throws(RuntimeError) -> [Container] { [] }
    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample { ContainerStatsSample() }
    func listVolumes() throws(RuntimeError) -> [Volume] { [] }
    func inspectVolume(named name: String) throws(RuntimeError) -> Volume? { nil }
    func deleteVolume(_ target: Volume) throws(RuntimeError) {}
    func listImages() throws(RuntimeError) -> ImageListSnapshot {
        ImageListSnapshot(images: [], isInfraFilterAuthoritative: true)
    }
    func deleteImage(reference: ImageRef) throws(RuntimeError) {}
}

@MainActor
@Suite("ContainerActionStore：stop/start/restart + 拒绝制（DAY13 工作项 1）")
struct ContainerActionStoreTests {

    static let runningID = ContainerID("web")!
    static let stoppedID = ContainerID("db")!

    static func fake() -> FakeContainerRuntimeClient {
        FakeContainerRuntimeClient(containers: [
            Container(
                id: runningID,
                image: ImageRef("docker.io/library/nginx:1")!,
                state: .running,
                environment: []
            ),
            Container(
                id: stoppedID,
                image: ImageRef("docker.io/library/postgres:16")!,
                state: .stopped,
                environment: []
            ),
        ])
    }

    /// 收集「动作结束回调」被调用的次数——列表刷新是注入的回调，
    /// store 不认识 `ContainerListStore`（裁决 #9）。
    @MainActor
    final class RefreshSpy {
        private(set) var count = 0
        func callback() -> @MainActor () async -> Void {
            { self.count += 1 }
        }
    }

    // MARK: - 成功路径

    @Test("stop 成功：上游收到一次 stop，容器变 stopped，回调触发一次")
    func stopSucceeds() async throws {
        let client = Self.fake()
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let accepted = await store.stop(id: Self.runningID)

        #expect(accepted)
        #expect(store.actionInProgress(for: Self.runningID) == nil)
        #expect(store.error(for: Self.runningID) == nil)
        #expect(spy.count == 1)

        let calls = await client.calls
        #expect(calls == [.stop(Self.runningID)])

        let container = try #require(await client.list().first { $0.id == Self.runningID })
        #expect(container.state == .stopped)
    }

    @Test("start 成功：上游收到一次 start，容器变 running，回调触发一次")
    func startSucceeds() async throws {
        let client = Self.fake()
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let accepted = await store.start(id: Self.stoppedID)

        #expect(accepted)
        #expect(store.error(for: Self.stoppedID) == nil)
        #expect(spy.count == 1)

        let calls = await client.calls
        #expect(calls == [.start(Self.stoppedID)])

        let container = try #require(await client.list().first { $0.id == Self.stoppedID })
        #expect(container.state == .running)
    }

    @Test("restart 成功：stop 后 start（上游无原生 restart），容器最终 running")
    func restartSucceeds() async throws {
        let client = Self.fake()
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let accepted = await store.restart(id: Self.runningID)

        #expect(accepted)
        #expect(store.error(for: Self.runningID) == nil)
        #expect(spy.count == 1)

        let calls = await client.calls
        #expect(calls == [.stop(Self.runningID), .start(Self.runningID)])

        let container = try #require(await client.list().first { $0.id == Self.runningID })
        #expect(container.state == .running)
    }

    // MARK: - 失败路径

    @Test("stop 失败：错误槽记 stopFailed，in-flight 清空，回调仍触发（列表可能已变）")
    func stopFailureRecorded() async {
        let client = Self.fake()
        await client.inject(.operationFailed(reason: "boom"), for: .stop)
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let accepted = await store.stop(id: Self.runningID)

        #expect(accepted)   // 被接受执行了，只是执行失败——和「被拒绝」是两码事
        #expect(store.actionInProgress(for: Self.runningID) == nil)
        #expect(store.error(for: Self.runningID) == .stopFailed(.operationFailed(reason: "boom")))
        #expect(spy.count == 1)
    }

    @Test("restart 半失败：stop 成功但 start 失败 → 必须报「已停止，但启动失败」，不是普通 startFailed")
    func restartHalfFailureIsDistinguished() async throws {
        let client = Self.fake()
        await client.inject(.operationFailed(reason: "image gone"), for: .start)
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let accepted = await store.restart(id: Self.runningID)

        #expect(accepted)
        #expect(
            store.error(for: Self.runningID)
                == .restartStartFailed(.operationFailed(reason: "image gone"))
        )
        #expect(spy.count == 1)

        // stop 确实生效了：容器停在 stopped——这正是这个错误必须单列的原因。
        let container = try #require(await client.list().first { $0.id == Self.runningID })
        #expect(container.state == .stopped)
    }

    @Test("restart 第一步失败：stop 失败 → restartStopFailed，不发 start")
    func restartStopFailureDoesNotStart() async {
        let client = Self.fake()
        await client.inject(.operationFailed(reason: "boom"), for: .stop)
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        _ = await store.restart(id: Self.runningID)

        #expect(
            store.error(for: Self.runningID)
                == .restartStopFailed(.operationFailed(reason: "boom"))
        )

        let calls = await client.calls
        #expect(calls == [.stop(Self.runningID)])   // 没有 .start
    }

    @Test("同容器新动作成功后清掉上一次错误（错误横幅不该永远挂着）")
    func successClearsPreviousError() async {
        let client = Self.fake()
        await client.inject(.operationFailed(reason: "boom"), for: .stop)
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        _ = await store.stop(id: Self.runningID)
        #expect(store.error(for: Self.runningID) != nil)

        await client.inject(nil, for: .stop)
        _ = await store.stop(id: Self.runningID)
        #expect(store.error(for: Self.runningID) == nil)
    }

    @Test("错误按容器隔离：Y 的成功/失败都不动 X 的错误槽（多详情窗同时开着的场景）")
    func errorsAreIsolatedPerContainer() async {
        let client = Self.fake()
        await client.inject(.operationFailed(reason: "boom"), for: .stop)
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        _ = await store.stop(id: Self.runningID)   // X 失败，横幅挂起
        #expect(store.error(for: Self.runningID) != nil)

        // Y 成功（start 未注入失败）→ X 的错误必须原地不动。
        _ = await store.start(id: Self.stoppedID)
        #expect(store.error(for: Self.runningID) == .stopFailed(.operationFailed(reason: "boom")))
        #expect(store.error(for: Self.stoppedID) == nil)
    }

    // MARK: - 拒绝制（裁决 #3：断言调用计数，不断言时序）

    @Test("同一容器动作进行中，新动作被拒：返回 false，上游计数不变")
    func concurrentActionOnSameContainerIsRejected() async {
        let client = GatedActionRuntimeClient()
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let first = Task { await store.stop(id: Self.runningID) }

        // 等第一个动作真的挂在上游上（in-flight 态确立）。
        while await client.pendingStopCount == 0 {
            await Task.yield()
        }
        #expect(store.actionInProgress(for: Self.runningID) == .stop)

        // 同容器再发起——三种动作全都要被拒。
        let secondStop = await store.stop(id: Self.runningID)
        let secondStart = await store.start(id: Self.runningID)
        let secondRestart = await store.restart(id: Self.runningID)

        #expect(!secondStop)
        #expect(!secondStart)
        #expect(!secondRestart)

        // 上游计数不变：连点两次 stop 只打一次上游。
        #expect(await client.stopCallCount == 1)
        #expect(await client.startCallCount == 0)

        await client.completeStop(0)
        let firstResult = await first.value
        #expect(firstResult)
        #expect(store.actionInProgress(for: Self.runningID) == nil)
        #expect(spy.count == 1)   // 被拒的动作不触发刷新回调
    }

    @Test("拒绝按容器粒度：A 进行中不挡 B")
    func actionOnDifferentContainerIsAllowed() async {
        let client = GatedActionRuntimeClient()
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        let first = Task { await store.stop(id: Self.runningID) }
        while await client.pendingStopCount == 0 {
            await Task.yield()
        }

        let second = Task { await store.stop(id: Self.stoppedID) }
        while await client.pendingStopCount < 2 {
            await Task.yield()
        }

        // 两个容器各自 in-flight，互不相拒。
        #expect(store.actionInProgress(for: Self.runningID) == .stop)
        #expect(store.actionInProgress(for: Self.stoppedID) == .stop)
        #expect(await client.stopCallCount == 2)

        await client.completeStop(0)
        await client.completeStop(1)
        #expect(await first.value)
        #expect(await second.value)
    }

    @Test("动作完成后同一容器可以再次发起（占位一定会被清掉，含失败路径）")
    func slotIsReleasedAfterCompletion() async {
        let client = Self.fake()
        await client.inject(.operationFailed(reason: "boom"), for: .stop)
        let spy = RefreshSpy()
        let store = ContainerActionStore(client: client, onActionCompleted: spy.callback())

        _ = await store.stop(id: Self.runningID)   // 失败
        await client.inject(nil, for: .stop)

        let accepted = await store.stop(id: Self.runningID)
        #expect(accepted)

        let calls = await client.calls
        #expect(calls == [.stop(Self.runningID), .stop(Self.runningID)])
    }
}
