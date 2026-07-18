import Testing

@testable import ContainerCore

/// `LogWindowStore`：日志窗口的 UI 编排。搬进 core（A1）之后第一次有测试覆盖——
/// 之前它住 app target，一行都测不了，「旧刷新覆盖新刷新」那一类 bug 只能靠肉眼 review 抓。
///
/// 断言**不变式本身**（`phase`/`lines` 的最终状态），不断言调度细节——
/// CLAUDE.md「断言副作用 = 跟调度器赛跑」的教训：等条件成立用 yield 轮询，不用 sleep 猜。
@MainActor
@Suite("LogWindowStore：fail-closed 脱敏 + 换代拆流 + 单飞")
struct LogWindowStoreTests {

    static func container(_ raw: String, environment: [EnvironmentVariable] = []) -> Container {
        Container(
            id: ContainerID(raw)!,
            image: ImageRef("oomol/connector:1.0")!,
            state: .running,
            environment: environment
        )
    }

    /// 等到条件成立，或者判定测试卡住了。
    private static func waitUntil(
        _ condition: @escaping () -> Bool,
        iterations: Int = 2_000
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("条件在预期时间内没有成立")
    }

    // MARK: - .unresolved → fail closed（D-B'）

    @Test(".unresolved → fail closed：不建 follow，不消费任何行")
    func unresolvedRedactionFailsClosed() async {
        let id = ContainerID("ghost")!
        let listClient = FakeContainerRuntimeClient(containers: [])
        let containers = ContainerListStore(client: listClient)
        await containers.refresh()  // .loaded([])：列表已加载完，但这个 id 不在里面

        let logClient = FakeContainerRuntimeClient(containers: [])
        await logClient.setLogLines([LogLine(text: "should never be read")])

        let store = LogWindowStore(
            id: id,
            client: logClient,
            containers: containers,
            currentGeneration: { nil }
        )

        store.open()

        #expect(store.phase == .unresolvedRedaction)
        #expect(store.lines.isEmpty)
        #expect(await logClient.calls.contains(.followLogs(id)) == false)
    }

    // MARK: - .resolved → 正常 follow

    @Test(".resolved → 正常 follow，快照最终写回 lines")
    func resolvedRedactionFollowsNormally() async {
        let container = Self.container("demo")
        let listClient = FakeContainerRuntimeClient(containers: [container])
        let containers = ContainerListStore(client: listClient)
        await containers.refresh()

        let logClient = FakeContainerRuntimeClient(containers: [container])
        // hangsAfterLines：流保持挂起，`phase` 稳定停在 `.following`——若不挂起，
        // 这个 2 行的假流几乎瞬间就会跟着 drain 完毕转成 `.streamEnded`，
        // `.following` 会窄成一个测不到的瞬间（不是生产代码的问题，是「一次性有限流」
        // 这个装置本身撑不起「稳定处于 following」这个断言窗口）。
        await logClient.setLogLines([LogLine(text: "hello"), LogLine(text: "world")], hangsAfterLines: true)

        let store = LogWindowStore(
            id: container.id,
            client: logClient,
            containers: containers,
            currentGeneration: { nil }
        )

        store.open()

        await Self.waitUntil { store.lines.count == 2 }

        #expect(store.phase == .following)
        #expect(store.lines.map(\.text) == ["hello", "world"])

        store.close()
    }

    // MARK: - L1'：换代 → generationStale，旧 tailer 被拆

    /// `startedGeneration` 在 `open()` 内**同步**捕获（早于任何 `await`）——所以只要在
    /// `open()` 返回之后、pollLoop 第一次跑之前把 `currentGeneration` 的返回值改掉，
    /// pollLoop 的第一次比较就必然抓到「变了」，不需要真的等 250ms 那一格轮询。
    @Test("generation 变化 → phase 变成 generationStale，旧 tailer 被拆（L1'）")
    func generationChangeMarksStaleAndDetachesTailer() async {
        let container = Self.container("demo")
        let listClient = FakeContainerRuntimeClient(containers: [container])
        let containers = ContainerListStore(client: listClient)
        await containers.refresh()

        let logClient = FakeContainerRuntimeClient(containers: [container])
        await logClient.setLogLines([LogLine(text: "hello")], hangsAfterLines: true)

        final class GenerationBox {
            var value: RuntimeGeneration?
            init(_ value: RuntimeGeneration?) { self.value = value }
        }
        let genA = RuntimeGeneration(pid: 1, startTime: 1)
        let genB = RuntimeGeneration(pid: 2, startTime: 2)
        let box = GenerationBox(genA)

        let store = LogWindowStore(
            id: container.id,
            client: logClient,
            containers: containers,
            currentGeneration: { box.value }
        )

        store.open()
        box.value = genB  // 抢在 pollLoop 的第一次检查之前变代

        await Self.waitUntil { store.phase == .generationStale }

        #expect(store.phase == .generationStale)
    }

    /// 反面：generation 没变，不该被误判成 stale。
    @Test("generation 不变 → 正常 following，不会被判成 stale")
    func stableGenerationDoesNotGoStale() async {
        let container = Self.container("demo")
        let listClient = FakeContainerRuntimeClient(containers: [container])
        let containers = ContainerListStore(client: listClient)
        await containers.refresh()

        let logClient = FakeContainerRuntimeClient(containers: [container])
        await logClient.setLogLines([LogLine(text: "steady")], hangsAfterLines: true)

        let gen = RuntimeGeneration(pid: 1, startTime: 1)

        let store = LogWindowStore(
            id: container.id,
            client: logClient,
            containers: containers,
            currentGeneration: { gen }
        )

        store.open()

        await Self.waitUntil { !store.lines.isEmpty }

        #expect(store.phase == .following)

        store.close()
    }

    // MARK: - 单飞：session-token

    /// 用一个可闸住 `followLogs` 的假运行时，精确制造「第二次 open() 先返回，
    /// 第一次 open() 后返回」的顺序——不靠 sleep 撞运气。
    private actor GatedLogClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {
        private var pending: [CheckedContinuation<AsyncThrowingStream<LogLine, any Error>, Never>] = []

        var pendingCount: Int { pending.count }

        func list() async throws(RuntimeError) -> [Container] { [] }
        func start(id: ContainerID) async throws(RuntimeError) {}
        func stop(id: ContainerID) async throws(RuntimeError) {}

        func followLogs(id: ContainerID) async throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
            }
        }

        func stats(id: ContainerID) async throws(RuntimeError) -> ContainerStatsSample {
            ContainerStatsSample()
        }

        /// 放行第 `index` 次发起的 `followLogs`，让它返回一个吐出 `lines` 就结束的流。
        func complete(_ index: Int, with lines: [LogLine]) {
            let stream = AsyncThrowingStream<LogLine, any Error> { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
            pending[index].resume(returning: stream)
        }
    }

    private static func waitForPending(_ count: Int, on client: GatedLogClient) async {
        for _ in 0..<20_000 {
            if await client.pendingCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 followLogs 请求")
    }

    @Test("连点两次 open()：先发起的那次即使后返回，也不许写回")
    func staleSessionResultsDoNotLandAfterNewerOpen() async {
        let container = Self.container("demo")
        let listClient = FakeContainerRuntimeClient(containers: [container])
        let containers = ContainerListStore(client: listClient)
        await containers.refresh()

        let gatedClient = GatedLogClient()

        let store = LogWindowStore(
            id: container.id,
            client: gatedClient,
            containers: containers,
            currentGeneration: { nil }
        )

        store.open()
        await Self.waitForPending(1, on: gatedClient)

        store.open()
        await Self.waitForPending(2, on: gatedClient)

        // 后发起的（第二次 open）先返回。
        await gatedClient.complete(1, with: [LogLine(text: "second")])
        await Self.waitUntil { !store.lines.isEmpty }

        // 先发起的（第一次 open）后返回——它已经被取代了，不该覆盖当前会话。
        await gatedClient.complete(0, with: [LogLine(text: "first")])

        // 给旧会话一点调度机会「本该」落地（若单飞失效，这里会看见 "first"）。
        for _ in 0..<50 { await Task.yield() }

        #expect(store.lines.map(\.text) == ["second"])

        store.close()
    }
}
