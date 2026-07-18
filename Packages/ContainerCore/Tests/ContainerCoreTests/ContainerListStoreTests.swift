import Testing

@testable import ContainerCore

/// 一个**可以精确控制返回时机**的运行时。
///
/// 乱序覆盖这类 bug，用「加个 sleep」是测不出来的：那只是把竞争变得更**可能**发生，
/// 没让它变得**必然**发生——测试于是变成随机绿。
///
/// 这里把每次 `list()` 挂在一个 continuation 上，由测试显式决定谁先返回。
/// 「后发起的先返回、先发起的后返回」这个顺序因此是确定的，不是撞运气撞出来的。
private actor GatedRuntimeClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private var pending: [CheckedContinuation<[Container], Never>] = []

    var pendingCount: Int { pending.count }

    func list() async throws(RuntimeError) -> [Container] {
        await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }

    /// 放行第 `index` 次发起的调用（0 起），让它返回 `containers`。
    func complete(_ index: Int, with containers: [Container]) {
        pending[index].resume(returning: containers)
    }

    func start(id: ContainerID) throws(RuntimeError) {}
    func stop(id: ContainerID) throws(RuntimeError) {}

    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample {
        ContainerStatsSample()
    }
}

@MainActor
@Suite("列表 store：刷新单飞，旧结果不得覆盖新结果")
struct ContainerListStoreTests {

    static func container(_ raw: String) -> Container {
        Container(
            id: ContainerID(raw)!,
            image: ImageRef("oomol/connector:1.0")!,
            state: .running,
            environment: []
        )
    }

    /// 等到 client 手上攒够 `count` 个未返回的调用。
    ///
    /// 用 `Task.yield()` 轮询而不是 sleep：协作式调度下 yield 会把执行权让给
    /// 还没跑到 `await` 的那个刷新任务，所以这是**确定**会推进的，不是靠等。
    private static func waitForPending(_ count: Int, on client: GatedRuntimeClient) async {
        for _ in 0..<10_000 {
            if await client.pendingCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途请求——store 可能压根没发起调用")
    }

    /// **codex review 找出的 P2。**
    ///
    /// `.task` 发起的刷新还挂在 `await client.list()` 上时，用户点了刷新按钮 → 第二次刷新。
    /// 两个请求的**返回顺序不由发起顺序决定**（M1 接上 XPC 后尤其如此）。
    /// 旧请求后返回并覆盖 `state`，用户看到的就是一份**已经被取代的**列表——
    /// 而且没有任何东西会纠正它，直到下一次刷新。
    ///
    /// `@MainActor` 挡不住这个：MainActor 在 `await` 处是**可重入**的。
    @Test("被取代的旧刷新，结果不许写回")
    func staleRefreshDoesNotOverwriteNewer() async {
        let client = GatedRuntimeClient()
        let store = ContainerListStore(client: client)

        let first = Task { await store.refresh() }
        await Self.waitForPending(1, on: client)

        let second = Task { await store.refresh() }
        await Self.waitForPending(2, on: client)

        // 后发起的先返回。
        await client.complete(1, with: [Self.container("new")])
        // 先发起的后返回——它已经被取代了，不该再写回。
        await client.complete(0, with: [Self.container("stale")])

        await first.value
        await second.value

        guard case .loaded(let containers) = store.state else {
            Issue.record("期望 loaded，实际 \(store.state)")
            return
        }
        #expect(containers.map(\.id.rawValue) == ["new"])
    }

    // MARK: - 基础行为

    @Test("初始是 loading")
    func startsLoading() {
        let store = ContainerListStore(client: FakeContainerRuntimeClient(containers: []))
        guard case .loading = store.state else {
            Issue.record("期望 loading，实际 \(store.state)")
            return
        }
    }

    @Test("刷新成功 → loaded")
    func refreshLoads() async {
        let store = ContainerListStore(client: FakeContainerRuntimeClient.preview)

        await store.refresh()

        guard case .loaded(let containers) = store.state else {
            Issue.record("期望 loaded，实际 \(store.state)")
            return
        }
        #expect(containers.count == 3)
    }

    /// 运行时挂掉时**保留上一次的快照**——这是本 App 最重要的一个 UI 决定。
    /// 清空列表，用户的第一反应是「我的容器被删了」；而真相是「运行时不在了，
    /// 这是它倒下前的样子」。
    @Test("刷新失败 → failed，且带着上一次的快照")
    func failureKeepsLastKnownSnapshot() async {
        let client = FakeContainerRuntimeClient.preview
        let store = ContainerListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .list)
        await store.refresh()

        guard case .failed(let error, let lastKnown) = store.state else {
            Issue.record("期望 failed，实际 \(store.state)")
            return
        }
        #expect(error == .runtimeUnavailable)
        #expect(lastKnown.count == 3)
    }

    /// 连续失败不该让快照在第二次失败时凭空消失。
    @Test("连续失败不丢快照")
    func repeatedFailureKeepsSnapshot() async {
        let client = FakeContainerRuntimeClient.preview
        let store = ContainerListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .list)
        await store.refresh()
        await store.refresh()

        guard case .failed(_, let lastKnown) = store.state else {
            Issue.record("期望 failed，实际 \(store.state)")
            return
        }
        #expect(lastKnown.count == 3)
    }

    /// 首次加载就失败（开机时运行时本来就没在跑）：没有快照可留，
    /// 此时才该显示纯粹的降级 UI。
    @Test("首次即失败 → 快照为空")
    func firstLoadFailureHasNoSnapshot() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.runtimeUnavailable, for: .list)
        let store = ContainerListStore(client: client)

        await store.refresh()

        guard case .failed(_, let lastKnown) = store.state else {
            Issue.record("期望 failed，实际 \(store.state)")
            return
        }
        #expect(lastKnown.isEmpty)
    }

    // MARK: - displayedContainers（详情窗口按 id 查它）

    @Test("displayedContainers：loading 时为空")
    func displayedEmptyWhileLoading() {
        let store = ContainerListStore(client: FakeContainerRuntimeClient(containers: []))
        #expect(store.displayedContainers.isEmpty)
    }

    @Test("displayedContainers：loaded 时就是那份列表")
    func displayedShowsLoaded() async {
        let store = ContainerListStore(client: FakeContainerRuntimeClient.preview)
        await store.refresh()
        #expect(store.displayedContainers.count == 3)
    }

    @Test("displayedContainers：运行时挂掉后仍是上一份快照（灰显详情靠它）")
    func displayedKeepsLastKnownOnFailure() async {
        let client = FakeContainerRuntimeClient.preview
        let store = ContainerListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .list)
        await store.refresh()

        #expect(store.displayedContainers.count == 3)
    }
}
