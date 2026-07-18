import Foundation
import Testing

@testable import ContainerCore

/// **Day 8：supervisor 的每一次决策都留下了痕迹。**
///
/// Day 7 的教训：M3 红的时候一行日志都没有，只能靠截图和临时真机测试去猜。这些测试守的是
/// 「该记的记了」——注一个 spy，把「运行时换代时有没有记下这次转移」变成对调用的断言。
///
/// 真正防「明文进 `.public` 日志」的是 `OSLogSupervisorLog` 的 `.private` 标注 +
/// `BoundaryScanner` 的专项规则；spy 只能证明**结构**（记的是 typed `RuntimeError`，不是裸字符串）。
@Suite("SupervisorLog")
struct SupervisorLogTests {

    private let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)
    private let g2 = RuntimeGeneration(pid: 200, startTime: 2_000)

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    private func container(_ raw: String) -> Container {
        Container(id: id(raw), image: ImageRef("busybox:1")!, state: .stopped, environment: [])
    }

    private func makeSupervisor(
        prober: FakeRuntimeProber,
        client: FakeContainerRuntimeClient,
        spy: SpySupervisorLog,
        config: SupervisorConfig = .default
    ) -> Supervisor {
        Supervisor(
            prober: prober,
            engine: WhitelistReconcileEngine(
                client: client,
                whitelist: FixedWhitelist(list: [
                    WhitelistEntry(id: id("a")),
                    WhitelistEntry(id: id("b")),
                ]),
                log: spy
            ),
            config: config,
            backoff: FixedBackoff(10),
            clock: ManualClock(),
            log: spy
        )
    }

    // MARK: - 成功路径

    @Test("down→up 成功：记下转移、reconcileStarted、reconcileOutcome(.success)")
    func logsSuccessfulReconcile() async {
        let spy = SpySupervisorLog()
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = makeSupervisor(prober: prober, client: client, spy: spy)

        await supervisor.step()                 // unknown → runtimeDown
        await prober.set(.running(g1))
        await supervisor.step()                 // runtimeDown → reconciling(g1)
        await supervisor.awaitReconcile()       // reconciling → runtimeUp(g1)

        let entries = spy.entries
        #expect(entries.contains(.transition(from: .unknown, to: .runtimeDown)))
        #expect(entries.contains(.reconcileStarted(g1)))
        #expect(entries.contains(.reconcileOutcome(.success, g1)))
        #expect(entries.contains(.transition(
            from: .reconciling(generation: g1, failures: nil),
            to: .runtimeUp(generation: g1, baseline: false)
        )))
    }

    // MARK: - 稳态不吵

    @Test("稳态同代 running：第二次 probe 不记任何东西")
    func steadyStateDoesNotLogDuplicateTransition() async {
        let spy = SpySupervisorLog()
        let prober = FakeRuntimeProber(.running(g1))
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        let supervisor = makeSupervisor(prober: prober, client: client, spy: spy)   // default: 冷启动不 reconcile

        await supervisor.step()                 // unknown → runtimeUp(g1, baseline: true)
        await supervisor.awaitReconcile()
        let afterFirst = spy.entries.count

        await supervisor.step()                 // running(g1) 又一次：reducer 不动作
        #expect(spy.entries.count == afterFirst) // 什么都没记——常驻进程每 2 秒不该刷屏
    }

    // MARK: - 失败路径

    @Test("reconcile 失败：记下 reconcileOutcome(.failure)、reconcileFailed 通知、以及 engine 诊断")
    func logsFailedReconcile() async {
        let spy = SpySupervisorLog()
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        await client.inject(.operationFailed(reason: "exit 1"), for: .start)
        let supervisor = makeSupervisor(prober: prober, client: client, spy: spy)

        await supervisor.step()
        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()

        let entries = spy.entries
        #expect(entries.contains(.reconcileOutcome(.failure(.transient), g1)))
        #expect(entries.contains { entry in
            if case .notice(.reconcileFailed(g1, .transient, _, _)) = entry { return true }
            return false
        })
        #expect(entries.contains(.containerStartFailed(id("a"), g1, .operationFailed(reason: "exit 1"))))
    }

    // MARK: - ★ D2：上游文本只以结构化 RuntimeError 记录

    @Test("含明文的 RuntimeError 以 typed enum 原样记录，分类为 transient")
    func diagnosticKeepsUpstreamTextStructured() async {
        let spy = SpySupervisorLog()
        let leaky = "OOMOL_CONNECT_ENCRYPTION_KEY=abc123"
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        await client.inject(.operationFailed(reason: leaky), for: .start)
        let engine = WhitelistReconcileEngine(
            client: client,
            whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("a"))]),
            log: spy
        )

        let outcome = await engine.reconcile(generation: g1)

        #expect(outcome == .failure(.transient))
        // spy 收到的是 typed `RuntimeError`（不是裸字符串）——明文只以结构化形式存在，
        // 是否进 .public 日志由 OSLogSupervisorLog 的 .private 标注决定（另有源码扫描守）。
        #expect(spy.entries == [.containerStartFailed(id("a"), g1, .operationFailed(reason: leaky))])
    }

    // MARK: - 手动兜底

    @Test("手动 force：记下 userForcedReconcile + reconcileStarted（区别于自动边沿）")
    func logsUserForcedReconcile() async {
        let spy = SpySupervisorLog()
        let prober = FakeRuntimeProber(.running(g1))
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        let supervisor = makeSupervisor(prober: prober, client: client, spy: spy)   // 冷启动 baseline，不自动拉

        await supervisor.step()
        await supervisor.awaitReconcile()
        await supervisor.forceReconcile()
        await supervisor.awaitReconcile()

        let entries = spy.entries
        #expect(entries.contains(.userForcedReconcile))
        #expect(entries.contains(.reconcileStarted(g1)))
    }
}
