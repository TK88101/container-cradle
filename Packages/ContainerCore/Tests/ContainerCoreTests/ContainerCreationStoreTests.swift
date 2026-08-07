import Testing

@testable import ContainerCore

/// T3（Day 16）：`ContainerCreationStore` 的提交流程——四路径 + 单飞。
///
/// 断言的是**调用序列/计数与终态 phase**（不变式），不断言下游后果，也不跟调度器赛跑
/// （坑清单「测副作用=跟调度器赛跑，必然假绿」）。
///
/// 四路径（Plan T3 DoD）：
/// 1. 提交成功——list（无碰名）→ create → start，phase=.succeeded，序列 [.list,.create,.start]（含「建后启」）。
/// 2. 名字已存在——list 命中 → **不调 create**（靠存在性不嗅错误码，R14），phase=.failed(.nameAlreadyExists)。
/// 3. 建后启——即路径 1 的序列断言 create 在 start 之前。
/// 4. 启动失败——create 成功但 start 抛 → **保留态、不调 delete**（不自动回滚），phase=.failed(.startFailed)。
/// **可精确控制 `list()` 返回时机**的运行时（同 `ContainerListStore` 的 `GatedRuntimeClient` 范式）。
///
/// 单飞测「第二次 submit 在第一次在途时被拒」不能靠 `Task.yield()` 撞时机——`FakeContainerRuntimeClient`
/// 的 `list()` 立即返回，第一次 submit 可能在第二次发起前就跑完 `.succeeded`，测试变随机绿（codex 抓到）。
/// 这里把 `list()` 挂在 continuation 上，测试用 `waitForPending` 确定性地等到第一次真的挂住（此刻
/// `phase==.submitting`，check+set 在 await 前同步完成）再发第二次，竞争因此**必然**发生而非碰运气。
///
/// `create` 自实现以**计数**（marker 的默认 create 会抛 unimplemented，用不了）；clone/pull/delete 及
/// volume/image 走 marker 默认。
private actor GatedCreationClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private var pending: [CheckedContinuation<[Container], Never>] = []
    private var containers: [Container]
    private(set) var createCount = 0

    init(containers: [Container] = []) {
        self.containers = containers
    }

    var pendingCount: Int { pending.count }

    func list() async throws(RuntimeError) -> [Container] {
        await withCheckedContinuation { pending.append($0) }
    }

    /// 放行第 `index` 次发起的 `list()`（0 起），让它返回当前容器列表。
    func completeList(_ index: Int) {
        pending[index].resume(returning: containers)
    }

    func create(_ spec: ContainerCreationSpec) throws(RuntimeError) -> ContainerID {
        createCount += 1
        guard let id = ContainerID(spec.name.value) else {
            throw .operationFailed(reason: "invalid container name '\(spec.name.value)'")
        }
        containers.append(
            Container(id: id, image: spec.image, state: .stopped, environment: spec.environment)
        )
        return id
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

@Suite("ContainerCreationStore 提交流程")
@MainActor
struct ContainerCreationStoreTests {

    private func makeSpec(name: String = "web", image: String = "nginx") throws -> ContainerCreationSpec {
        try ContainerCreationSpec(
            name: try ContainerName(name),
            image: try #require(ImageRef(image)),
            volumeMounts: [],
            environment: []
        )
    }

    // MARK: - 路径 1 + 3：提交成功（建后启序列）

    @Test("提交成功：list→create→start 全走通，phase=succeeded")
    func submitSucceeds() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        let accepted = await store.submit(spec, startAfterCreate: true)

        #expect(accepted)
        let name = try ContainerName("web")
        let id = try #require(ContainerID("web"))
        #expect(await fake.calls == [.list, .create(name), .start(id)])
        #expect(store.phase == .succeeded(id))
    }

    // MARK: - 路径 2：名字已存在 → 拒绝，不调 create

    @Test("名字已存在：list 命中 → 不调 create，phase=failed(.nameAlreadyExists)")
    func rejectsExistingName() async throws {
        let existing = Container(
            id: try #require(ContainerID("web")),
            image: try #require(ImageRef("nginx")),
            state: .running,
            environment: []
        )
        let fake = FakeContainerRuntimeClient(containers: [existing])
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        let accepted = await store.submit(spec, startAfterCreate: true)

        #expect(accepted) // 处理了（不是单飞拒），只是终态是 failed
        #expect(await fake.calls == [.list]) // create 未被调用
        #expect(store.phase == .failed(.nameAlreadyExists(try #require(ContainerID("web")))))
    }

    // MARK: - 路径 4：创建成功但启动失败 → 保留态、不调 delete

    @Test("启动失败：保留态、不调 delete，phase=failed(.startFailed)")
    func startFailureKeepsContainerNoRollback() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.operationFailed(reason: "boom"), for: .start)
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        let accepted = await store.submit(spec, startAfterCreate: true)

        #expect(accepted)
        let name = try ContainerName("web")
        let id = try #require(ContainerID("web"))
        let calls = await fake.calls
        #expect(calls == [.list, .create(name), .start(id)])
        #expect(!calls.contains(.deleteContainer(id))) // 绝不自动回滚删除
        #expect(store.phase == .failed(.startFailed(id, .operationFailed(reason: "boom"))))
        // 保留态：create 出来的容器仍在（stopped），用户可稍后手动启动
        #expect(try await fake.list().contains { $0.id == id })
    }

    // MARK: - 创建失败 → 不调 start

    @Test("创建失败：phase=failed(.createFailed)，不调 start")
    func createFailureDoesNotStart() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.mountSourceUnavailable(path: "/x"), for: .create)
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        let accepted = await store.submit(spec, startAfterCreate: true)

        #expect(accepted)
        let name = try ContainerName("web")
        #expect(await fake.calls == [.list, .create(name)]) // start 未被调用
        #expect(store.phase == .failed(.createFailed(.mountSourceUnavailable(path: "/x"))))
    }

    // MARK: - list 前置失败 → 不调 create（不在存在性未知时盲建）

    @Test("前置 list 失败：不调 create，phase=failed(.precheckFailed)")
    func precheckListFailureDoesNotCreate() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.runtimeUnavailable, for: .list)
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        let accepted = await store.submit(spec, startAfterCreate: true)

        #expect(accepted)
        #expect(await fake.calls == [.list]) // create 未被调用
        #expect(store.phase == .failed(.precheckFailed(.runtimeUnavailable)))
    }

    // MARK: - 单飞：在途时第二次 submit 立即被拒（确定性门控，不撞调度器）

    /// 确定性地等到 client 手上攒够 `count` 个挂起的 `list()`（同 `ContainerListStore` 的
    /// `waitForPending`）：`Task.yield()` 在协作式调度下把执行权让给还没跑到 `await` 的提交任务，
    /// 所以这**必然**推进，不是靠等时长。
    private func waitForPending(_ count: Int, on client: GatedCreationClient) async {
        for _ in 0..<10_000 {
            if await client.pendingCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 list()——store 可能压根没发起提交")
    }

    @Test("单飞：第一次在途（挂在 list 门控）时，第二次 submit 被拒且不重复 create")
    func singleFlightRejectsSecondSubmit() async throws {
        let client = GatedCreationClient()
        let store = ContainerCreationStore(client: client)
        let spec = try makeSpec(name: "web")

        let t1 = Task { await store.submit(spec, startAfterCreate: true) }
        // 确定性等到 t1 真的挂在 list() 门控上——此刻 phase==.submitting（check+set 在 await 前同步完成）。
        await waitForPending(1, on: client)

        // 第二次 submit 命中单飞守卫 → 立即拒（返回 false，不进 list/create）。
        let secondAccepted = await store.submit(spec, startAfterCreate: true)
        #expect(!secondAccepted)

        // 放行 t1：create → start → succeeded。
        await client.completeList(0)
        let firstAccepted = await t1.value

        #expect(firstAccepted)
        // 断言不变式：create 只发生一次（不断言时序下游）。
        #expect(await client.createCount == 1)
    }

    // MARK: - T9.4b：只建不启（`startAfterCreate: false`）

    /// 上位 Plan §1.1 的「创建」按钮（区别于「创建并启动」）。**参数没有默认值**是刻意的：
    /// 两条路径的失败形态结构上不同（`false` 时 `.startFailed` 不可能出现），
    /// 默认值会让调用点读不出自己走的是哪条。
    @Test("startAfterCreate=false：create 后不调 start，phase=succeeded")
    func submitWithoutStart() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        let accepted = await store.submit(spec, startAfterCreate: false)

        #expect(accepted)
        let name = try ContainerName("web")
        let id = try #require(ContainerID("web"))
        // 调用序列断言（不变式）：start 根本没发生。
        #expect(await fake.calls == [.list, .create(name)])
        #expect(store.phase == .succeeded(id))
    }

    /// 注入 start 失败也不该改变结论——`false` 路径压根不碰 start。
    @Test("startAfterCreate=false：即使 start 会失败，也仍然 succeeded")
    func submitWithoutStartIgnoresStartFailure() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.operationFailed(reason: "boom"), for: .start)
        let store = ContainerCreationStore(client: fake)
        let spec = try makeSpec(name: "web")

        await store.submit(spec, startAfterCreate: false)

        #expect(store.phase == .succeeded(try #require(ContainerID("web"))))
    }

    // MARK: - T9.4b：reset()

    @Test("reset：终态回 .idle，可再次提交")
    func resetReturnsToIdle() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let store = ContainerCreationStore(client: fake)
        await store.submit(try makeSpec(name: "web"), startAfterCreate: false)
        #expect(store.phase != .idle)

        store.reset()

        #expect(store.phase == .idle)
    }

    @Test("reset：失败终态同样回 .idle")
    func resetFromFailure() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.runtimeUnavailable, for: .list)
        let store = ContainerCreationStore(client: fake)
        await store.submit(try makeSpec(name: "web"), startAfterCreate: true)
        #expect(store.phase == .failed(.precheckFailed(.runtimeUnavailable)))

        store.reset()

        #expect(store.phase == .idle)
    }
}
