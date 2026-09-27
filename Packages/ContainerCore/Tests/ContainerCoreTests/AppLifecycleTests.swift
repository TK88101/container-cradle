import Foundation
import Testing

@testable import ContainerCore

/// App 启动 / 退出的交错（codex R5 补评 P1）：`start()` 挂在 await 上时退出先做完，旧的 `start()` 续体恢复后照样
/// `recoverIfNeeded()`、起调度器——盘上若有崩溃遗留的记录，恢复会在 supervisor 已停之后起运行时、拉容器。
@MainActor
@Suite("AppLifecycle：启动途中退出 → 启动的续体什么都不再做；supervisor 最后一个动作是停；两次退出共用一次收尾")
struct AppLifecycleTests {

    typealias T = RuntimeUpdateStoreTests

    @MainActor
    final class Recorder {
        private(set) var events: [String] = []
        func append(_ event: String) { events.append(event) }
        func count(_ event: String) -> Int { events.filter { $0 == event }.count }
        func index(of event: String) -> Int? { events.firstIndex(of: event) }
        /// supervisor 收到的最后一个生命周期动作。
        var lastSupervisorCall: String? { events.last { $0.hasPrefix("sv-") } }
    }

    static func lifecycle(
        _ r: Recorder,
        startSupervisor: (@MainActor () async -> Void)? = nil,
        loadWhitelist: (@MainActor () async -> Void)? = nil,
        prepareForQuit: (@MainActor () async -> Void)? = nil
    ) -> AppLifecycle {
        AppLifecycle(steps: .init(
            beginStartup: { r.append("startup") },
            startSupervisor: startSupervisor ?? { r.append("sv-start") },
            loadWhitelist: loadWhitelist ?? { r.append("load") },
            beginBackgroundWork: { r.append("background") },
            prepareForQuit: prepareForQuit ?? { r.append("prepare") },
            stopSupervisor: { r.append("sv-stop") }
        ))
    }

    // MARK: - 正控制

    @Test("正常启动再退出：启动三步按序；退出先准备、再停 supervisor")
    func startThenStop() async {
        let r = Recorder()
        let lifecycle = Self.lifecycle(r)
        await lifecycle.start()
        await lifecycle.stop()
        #expect(r.events == ["startup", "sv-start", "load", "background", "prepare", "sv-stop"])
    }

    // MARK: - P1：启动途中退出

    @Test("supervisor 首轮探测途中退出 → 启动的续体不读白名单、不恢复、不起调度器")
    func quitDuringSupervisorStart() async {
        let r = Recorder()
        let gate = Gate()
        let lifecycle = Self.lifecycle(r, startSupervisor: { r.append("sv-start"); await gate.wait() })
        let starting = Task { await lifecycle.start() }
        while r.count("sv-start") == 0 { await Task.yield() }
        await lifecycle.stop()
        gate.open()
        await starting.value
        #expect(r.count("load") == 0)
        #expect(r.count("background") == 0)
        #expect(r.lastSupervisorCall == "sv-stop")
    }

    @Test("读白名单途中退出 → 不恢复、不起调度器")
    func quitDuringWhitelistLoad() async {
        let r = Recorder()
        let gate = Gate()
        let lifecycle = Self.lifecycle(r, loadWhitelist: { r.append("load"); await gate.wait() })
        let starting = Task { await lifecycle.start() }
        while r.count("load") == 0 { await Task.yield() }
        await lifecycle.stop()
        gate.open()
        await starting.value
        #expect(r.count("background") == 0)
    }

    /// 退出的交接最长 60 秒（QuitHandOff）：启动的续体完全可能在退出**做到一半**时恢复——阶段必须在 `stop()` 入口、任何 await 之前就推到 stopping。
    @Test("退出做到一半（还在交接）时启动的续体恢复 → 同样不读白名单、不恢复、不起调度器")
    func startResumesWhileQuitIsInProgress() async {
        let r = Recorder()
        let startGate = Gate()
        let quitGate = Gate()
        let lifecycle = Self.lifecycle(
            r,
            startSupervisor: { r.append("sv-start"); await startGate.wait() },
            prepareForQuit: { r.append("prepare"); await quitGate.wait() }
        )
        let starting = Task { await lifecycle.start() }
        while r.count("sv-start") == 0 { await Task.yield() }
        let stopping = Task { await lifecycle.stop() }
        while r.count("prepare") == 0 { await Task.yield() }
        startGate.open()
        await starting.value
        #expect(r.count("load") == 0)
        #expect(r.count("background") == 0)
        // 退出还没走到停 supervisor（卡在交接）：start 续体不许抢着停——交接要一个活的 supervisor（R6：原先没有断言守它）。
        #expect(r.count("sv-stop") == 0)
        quitGate.open()
        await stopping.value
        #expect(r.lastSupervisorCall == "sv-stop")
    }

    @Test("退出先于启动（didFinishLaunching 的任务还没被调度到）→ 启动什么都不做，supervisor 不会在停之后被起")
    func stopBeforeStartMakesStartANoOp() async {
        let r = Recorder()
        let lifecycle = Self.lifecycle(r)
        await lifecycle.stop()
        await lifecycle.start()
        #expect(r.events == ["prepare", "sv-stop"])
    }

    /// actor 上的执行次序不由发起次序保证：`supervisor.start()` 的方法体可能晚于退出那句 `supervisor.stop()` 落地
    /// （它会把 `isStopped` 清掉、装上轮询循环）。这里让 start 的效果在放行之后才发生，模拟「晚落地」。
    @Test("supervisor 的 start 晚于退出的 stop 落地 → 再停一次：supervisor 最后收到的是停")
    func supervisorStartLandingAfterStopIsStoppedAgain() async {
        let r = Recorder()
        let gate = Gate()
        let lifecycle = Self.lifecycle(r, startSupervisor: { r.append("entered"); await gate.wait(); r.append("sv-start") })
        let starting = Task { await lifecycle.start() }
        while r.count("entered") == 0 { await Task.yield() }
        await lifecycle.stop()
        #expect(r.count("sv-stop") == 1)
        gate.open()
        await starting.value
        #expect(r.count("sv-start") == 1)
        #expect(r.lastSupervisorCall == "sv-stop")
    }

    /// 退出那句停已经发出、还没返回（跨 actor 的跳转在途），start 的方法体恰在它之后落地：「已发出停」必须在发出**之前**就记下。
    @Test("supervisor 的 start 在退出那句停「在途」时落地 → 同样再停一次")
    func supervisorStartLandingWhileStopInFlightIsStoppedAgain() async {
        let r = Recorder()
        let startGate = Gate()
        let stopGate = Gate()
        let lifecycle = AppLifecycle(steps: .init(
            beginStartup: {},
            startSupervisor: { r.append("entered"); await startGate.wait(); r.append("sv-start") },
            loadWhitelist: { r.append("load") },
            beginBackgroundWork: { r.append("background") },
            prepareForQuit: { r.append("prepare") },
            stopSupervisor: {
                r.append("sv-stop")
                if r.count("sv-stop") == 1 { await stopGate.wait() }   // 第一次停：效果已落地，调用还没返回
            }
        ))
        let starting = Task { await lifecycle.start() }
        while r.count("entered") == 0 { await Task.yield() }
        let stopping = Task { await lifecycle.stop() }
        while r.count("sv-stop") == 0 { await Task.yield() }
        startGate.open()
        await starting.value
        #expect(r.count("sv-start") == 1)
        #expect(r.lastSupervisorCall == "sv-stop")
        stopGate.open()
        await stopping.value
    }

    // MARK: - 两次退出

    /// `applicationShouldTerminate` 返回 `.terminateLater` 之后若再被调一次：第二次的 `reply` 若在收尾完成前发出，
    /// 进程会在交接 / 等升级做到一半时退出。
    @Test("退出被触发两次 → 共用一次收尾；第二次在收尾完成之后才返回")
    func secondStopAwaitsTheFirst() async {
        let r = Recorder()
        let gate = Gate()
        let lifecycle = Self.lifecycle(r, prepareForQuit: { r.append("prepare"); await gate.wait() })
        let first = Task { await lifecycle.stop() }
        while r.count("prepare") == 0 { await Task.yield() }
        // 标记与 `stop()` 的入口之间没有挂起点：看到标记 ⇒ 第二次调用已经进了 stop（立即返回的实现此刻已记下 second-returned）。
        let second = Task { r.append("second-called"); await lifecycle.stop(); r.append("second-returned") }
        while r.count("second-called") == 0 { await Task.yield() }
        gate.open()
        await first.value
        await second.value
        #expect(r.count("prepare") == 1)
        #expect(r.count("sv-stop") == 1)
        let stopped = r.index(of: "sv-stop")
        let returned = r.index(of: "second-returned")
        #expect(stopped != nil && returned != nil && returned! > stopped!)
    }

    // MARK: - 接上真的更新器（codex 的原始时间线）

    static func realStoreLifecycle(_ h: T.Harness, startSupervisor: @escaping @MainActor () async -> Void) -> AppLifecycle {
        let store = h.store
        return AppLifecycle(steps: .init(
            beginStartup: {},
            startSupervisor: startSupervisor,
            loadWhitelist: {},
            beginBackgroundWork: { store.recoverIfNeeded() },
            prepareForQuit: { await store.prepareForTermination() },
            stopSupervisor: {}
        ))
    }

    @Test("正控制：盘上有崩溃遗留的记录、正常启动 → 恢复起运行时、拉容器")
    func recoveryRunsOnNormalStart() async throws {
        let h = try T.Harness(script: .init(runtimeRunning: false, running: []))
        h.prefs.intent = T.intent(stopIssued: true)
        let lifecycle = Self.realStoreLifecycle(h, startSupervisor: {})
        await lifecycle.start()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
    }

    /// codex R6 5a：读白名单可能被网络家目录拖慢——这段时间里按钮若从盘上的记录露出来，按下会抢先清掉记录，恢复流程报不出状态文件的结论。
    @Test("冷启动卡在读白名单：盘上有崩溃遗留的记录，按钮不出现、按下无效；放行后恢复照常跑完（拉容器、请受管 reconcile、报状态文件的结论）")
    func manualRestoreHiddenUntilStartupRecovery() async throws {
        let h = try T.Harness(script: .init(installed: .installed(T.v150), runtimeRunning: true, running: []))
        h.prefs.intent = T.intent(stopIssued: true)
        h.installer.stateFile.withLock { $0 = .done(.installed) }
        let r = Recorder()
        let gate = Gate()
        let store = h.store
        let lifecycle = AppLifecycle(steps: .init(
            beginStartup: {},
            startSupervisor: {},
            loadWhitelist: { r.append("load"); await gate.wait() },
            beginBackgroundWork: { store.recoverIfNeeded() },
            prepareForQuit: { await store.prepareForTermination() },
            stopSupervisor: {}
        ))
        let starting = Task { await lifecycle.start() }
        while r.count("load") == 0 { await Task.yield() }
        #expect(store.manualRestore == nil)
        store.startRuntime()
        #expect(store.task == nil)

        gate.open()
        await starting.value
        await store.awaitOperationForTests()
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.log.count("reconcile") == 1)
        #expect(store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.prefs.intent == nil)
    }

    @Test("盘上有崩溃遗留的记录、启动途中退出 → 恢复不会在退出之后起运行时 / 拉容器；记录留给下次启动")
    func quitDuringStartDoesNotRecoverAfterwards() async throws {
        let h = try T.Harness(script: .init(runtimeRunning: false, running: []))
        let intent = T.intent(stopIssued: true)
        h.prefs.intent = intent
        let r = Recorder()
        let gate = Gate()
        let lifecycle = Self.realStoreLifecycle(h, startSupervisor: { r.append("sv-start"); await gate.wait() })
        let starting = Task { await lifecycle.start() }
        while r.count("sv-start") == 0 { await Task.yield() }
        await lifecycle.stop()
        gate.open()
        await starting.value
        await h.store.awaitOperationForTests()
        #expect(h.log.count("lock") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("start:buildkit") == 0)
        #expect(h.prefs.intent == intent)
        #expect(h.store.state == .idle)
    }
}
