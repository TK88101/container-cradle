import Foundation
import Synchronization
import Testing

@testable import ContainerCore

// MARK: - Fakes

/// 更新器一侧的仲裁者（租约 + 「盘上意图欠不欠起运行时」）。
@MainActor
final class FakeRuntimeArbiter: RuntimeOperationArbitrating {
    var isPrimaryInstance = true
    var pendingIntentOwesRuntimeStart = false
    /// 真 ⇒ 拿不到租约（模拟更新器正忙）。
    var refuseLease = false
    private(set) var held: ExternalRuntimeToken?
    private(set) var grants = 0

    func tryBeginExternalRuntimeOperation() -> ExternalRuntimeToken? {
        guard !refuseLease, held == nil else { return nil }
        grants += 1
        let token = ExternalRuntimeToken()
        held = token
        return token
    }

    func endExternalRuntimeOperation(_ token: ExternalRuntimeToken) {
        guard held == token else { return }
        held = nil
    }
}

/// 可闸住的一次性挂起点：`wait()` 挂住直到 `open()`；`hangForever` 时用不响应取消的 continuation 挂死。
final class StepGate: @unchecked Sendable {
    private let state = Mutex<(entered: Bool, continuation: CheckedContinuation<Void, Never>?, opened: Bool)>((false, nil, false))
    let hangForever: Bool
    init(hangForever: Bool = false) { self.hangForever = hangForever }

    func wait() async {
        if hangForever {
            state.withLock { $0.entered = true }
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return
        }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                s.entered = true
                if s.opened { return true }
                s.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var entered: Bool { state.withLock { $0.entered } }

    func open() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.opened = true
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume()
    }
}

final class FakeStarterCommands: RuntimeStarting, @unchecked Sendable {
    let log: EventLog
    struct Script {
        var running = false
        var runningAfterStart = true
        var start: CommandOutcome = .succeeded
        var locks: [PrivilegedJobState] = [.idle]
    }
    let script: Mutex<Script>
    let isRunningGate = Mutex<StepGate?>(nil)
    let lockGate = Mutex<StepGate?>(nil)
    let startGate = Mutex<StepGate?>(nil)
    private let lockCount = Mutex(0)
    private let started = Mutex(false)

    init(log: EventLog, _ script: Script = Script()) {
        self.log = log
        self.script = Mutex(script)
    }

    func isRuntimeRunning() async -> Bool {
        if let gate = isRunningGate.withLock({ $0 }) { await gate.wait() }
        log.append("is-running")
        let didStart = started.withLock { $0 }
        return script.withLock { s in didStart ? s.runningAfterStart : s.running }
    }

    func privilegedJobState() async -> PrivilegedJobState {
        if let gate = lockGate.withLock({ $0 }) { await gate.wait() }
        log.append("lock")
        let n = lockCount.withLock { $0 += 1; return $0 }
        return script.withLock { s in s.locks[min(n, s.locks.count) - 1] }
    }

    func startRuntime(allowKernelInstall: Bool) async -> CommandOutcome {
        if let gate = startGate.withLock({ $0 }) { await gate.wait() }
        log.append("start-runtime(kernel:\(allowKernelInstall))")
        let outcome = script.withLock { $0.start }
        if outcome == .succeeded { started.withLock { $0 = true } }
        return outcome
    }
}

@MainActor
final class InMemoryAutoStartPreferences: RuntimeAutoStartPreferences {
    var isEnabled = true
}

final class SpyAutoStartLog: RuntimeAutoStartLog, @unchecked Sendable {
    enum Event: Equatable {
        case skipped(RuntimeAutoStartTrigger, RuntimeAutoStartSkip)
        case deferred(RuntimeAutoStartTrigger, RuntimeAutoStartDeferral, attempt: Int)
        case started(RuntimeAutoStartTrigger, kernelInstall: Bool)
        case succeeded(RuntimeAutoStartTrigger)
        case failed(RuntimeAutoStartTrigger, RuntimeAutoStartFailure)
    }
    private let recorded = Mutex<[Event]>([])
    var events: [Event] { recorded.withLock { $0 } }
    func skipped(trigger: RuntimeAutoStartTrigger, reason: RuntimeAutoStartSkip) { recorded.withLock { $0.append(.skipped(trigger, reason)) } }
    func deferred(trigger: RuntimeAutoStartTrigger, reason: RuntimeAutoStartDeferral, attempt: Int) {
        recorded.withLock { $0.append(.deferred(trigger, reason, attempt: attempt)) }
    }
    func started(trigger: RuntimeAutoStartTrigger, kernelInstall: Bool) { recorded.withLock { $0.append(.started(trigger, kernelInstall: kernelInstall)) } }
    func succeeded(trigger: RuntimeAutoStartTrigger) { recorded.withLock { $0.append(.succeeded(trigger)) } }
    func failed(trigger: RuntimeAutoStartTrigger, failure: RuntimeAutoStartFailure, detail: String?) {
        recorded.withLock { $0.append(.failed(trigger, failure)) }
    }
}

// MARK: - Tests

/// Day 23 T3：重启 Mac 后运行时不会自己起来（上游 apiserver 是 `system start` 时才 bootstrap 的 launch agent）。
/// App 启动时补这一步，其余交给现有 supervisor（Plan 2026-09-29 §2）。
@MainActor
@Suite("RuntimeAutoStarter：启动时自动起运行时")
struct RuntimeAutoStarterTests {

    @MainActor
    final class Harness {
        let log = EventLog()
        let arbiter = FakeRuntimeArbiter()
        let commands: FakeStarterCommands
        let prefs = InMemoryAutoStartPreferences()
        let spy = SpyAutoStartLog()
        let clock = ManualClock()
        var managed = true
        var failures: [RuntimeAutoStartFailure] = []
        private(set) var starter: RuntimeAutoStarter!

        init(_ script: FakeStarterCommands.Script = .init()) {
            commands = FakeStarterCommands(log: log, script)
            starter = makeStarter()
        }

        func makeStarter(reconcile: (@MainActor () async -> Void)? = nil) -> RuntimeAutoStarter {
            let log = self.log
            let starter = RuntimeAutoStarter(
                commands: commands,
                arbiter: arbiter,
                preferences: prefs,
                clock: clock,
                log: spy,
                hasManagedContainers: { [unowned self] in managed },
                reconcileManagedNow: reconcile ?? { log.append("reconcile") }
            )
            starter.onFailure = { [unowned self] failure in failures.append(failure) }
            return starter
        }

        func launch() async {
            starter.startOnLaunchIfNeeded()
            await starter.awaitRunForTests()
        }

        func press() async {
            starter.startNow()
            await starter.awaitRunForTests()
        }

        /// 让 starter 的 task 跑到下一个挂起点（延后等待 / 闸住时用）。
        func settle() async {
            for _ in 0..<200 { await Task.yield() }
        }
    }

    // MARK: 成功路径

    @Test("★ 运行时没在跑 → 起它（不装内核）→ 请 supervisor reconcile；租约用完即还")
    func startsRuntimeOnLaunch() async {
        let h = Harness()
        await h.launch()
        #expect(h.log.all == ["is-running", "lock", "start-runtime(kernel:false)", "is-running", "reconcile"])
        #expect(h.starter.state == .idle)
        #expect(h.arbiter.held == nil)
        #expect(h.arbiter.grants == 1)
        #expect(h.failures.isEmpty)
        #expect(h.spy.events == [.started(.appLaunch, kernelInstall: false), .succeeded(.appLaunch)])
    }

    @Test("租约在 reconcile 之前就已归还（reconcile 不与更新器争运行时）")
    func leaseReleasedBeforeReconcile() async {
        let h = Harness()
        var heldDuringReconcile: Bool?
        let starter = h.makeStarter(reconcile: { [arbiter = h.arbiter] in heldDuringReconcile = arbiter.held != nil })
        starter.startOnLaunchIfNeeded()
        await starter.awaitRunForTests()
        #expect(heldDuringReconcile == false)
    }

    @Test("启动时只认领一次：第二次调用什么都不做")
    func launchClaimedOnce() async {
        let h = Harness()
        await h.launch()
        await h.launch()
        #expect(h.log.count("start-runtime(kernel:false)") == 1)
    }

    @Test("横幅按钮：忽略开关与空白名单，允许装内核")
    func buttonIgnoresToggleAndAllowsKernel() async {
        let h = Harness()
        h.starter.isEnabled = false
        h.managed = false
        await h.press()
        #expect(h.log.count("start-runtime(kernel:true)") == 1)
        #expect(h.spy.events.first == .started(.userButton, kernelInstall: true))
    }

    // MARK: 终局跳过

    @Test("开关关着 → 跳过，不探测")
    func skipsWhenDisabled() async {
        let h = Harness()
        h.starter.isEnabled = false
        await h.launch()
        #expect(h.log.all.isEmpty)
        #expect(h.spy.events == [.skipped(.appLaunch, .disabled)])
        #expect(h.starter.state == .idle)
    }

    @Test("白名单没有受管容器 → 跳过（起了也不服务 supervisor）")
    func skipsWithoutManagedContainers() async {
        let h = Harness()
        h.managed = false
        await h.launch()
        #expect(h.log.all.isEmpty)
        #expect(h.spy.events == [.skipped(.appLaunch, .noManagedContainers)])
    }

    @Test("非主实例 → 跳过")
    func skipsOnSecondary() async {
        let h = Harness()
        h.arbiter.isPrimaryInstance = false
        await h.launch()
        #expect(h.log.all.isEmpty)
        #expect(h.spy.events == [.skipped(.appLaunch, .notPrimary)])
    }

    @Test("运行时已经在跑 → 跳过、不 start、不 reconcile（交给 supervisor）")
    func skipsWhenAlreadyRunning() async {
        let h = Harness(.init(running: true))
        await h.launch()
        #expect(h.log.all == ["is-running"])
        #expect(h.spy.events == [.skipped(.appLaunch, .alreadyRunning)])
        #expect(h.arbiter.held == nil)
    }

    @Test("退出开始之后 → 不做任何事")
    func skipsAfterTermination() async {
        let h = Harness()
        h.starter.beginTermination()
        await h.launch()
        #expect(h.log.all.isEmpty)
    }

    // MARK: 延后（暂时互斥 ≠ 失败）

    @Test("盘上意图真欠「起运行时」→ 让路给更新器的恢复；恢复把运行时起了 → 重判为已在跑")
    func defersToUpdaterRecovery() async {
        let h = Harness()
        h.arbiter.pendingIntentOwesRuntimeStart = true
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        guard case .deferred(.updaterOwesRuntimeStart) = h.starter.state else {
            Issue.record("state = \(h.starter.state)")
            return
        }
        #expect(h.log.all.isEmpty)

        h.arbiter.pendingIntentOwesRuntimeStart = false
        h.commands.script.withLock { $0.running = true }
        await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        await h.starter.awaitRunForTests()
        #expect(h.log.all == ["is-running"])
        #expect(h.starter.state == .idle)
        #expect(h.spy.events.last == .skipped(.appLaunch, .alreadyRunning))
    }

    @Test("遗留但不欠起运行时的意图记录 → 不挡")
    func staleIntentDoesNotBlock() async {
        let h = Harness()
        h.arbiter.pendingIntentOwesRuntimeStart = false
        await h.launch()
        #expect(h.log.count("start-runtime(kernel:false)") == 1)
    }

    @Test("更新器正忙 → 延后；30 秒后不忙了 → 启动")
    func defersWhileUpdaterBusy() async {
        let h = Harness()
        h.arbiter.refuseLease = true
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        guard case .deferred(.updaterBusy) = h.starter.state else {
            Issue.record("state = \(h.starter.state)")
            return
        }
        #expect(h.spy.events == [.deferred(.appLaunch, .updaterBusy, attempt: 1)])
        h.arbiter.refuseLease = false
        await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        await h.starter.awaitRunForTests()
        #expect(h.log.count("start-runtime(kernel:false)") == 1)
        #expect(h.starter.state == .idle)
    }

    @Test("root 升级锁被持有 → 延后并归还租约；锁空闲后启动")
    func defersWhilePrivilegedJobRuns() async {
        let h = Harness(.init(locks: [.running, .idle]))
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        guard case .deferred(.privilegedJobRunning) = h.starter.state else {
            Issue.record("state = \(h.starter.state)")
            return
        }
        #expect(h.arbiter.held == nil)
        await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        await h.starter.awaitRunForTests()
        #expect(h.log.count("start-runtime(kernel:false)") == 1)
    }

    @Test("锁探测失败 → 延后（不当成空闲）")
    func defersOnLockProbeFailure() async {
        let h = Harness(.init(locks: [.probeFailed(1), .idle]))
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        guard case .deferred(.lockProbeFailed) = h.starter.state else {
            Issue.record("state = \(h.starter.state)")
            return
        }
        #expect(h.log.count("start-runtime(kernel:false)") == 0)
    }

    @Test("延后次数耗尽 → blockedByUpdater，通知一次")
    func deferralExhausted() async {
        let h = Harness()
        h.arbiter.refuseLease = true
        h.starter.startOnLaunchIfNeeded()
        for _ in 0..<RuntimeAutoStarter.maxDeferrals {
            await h.settle()
            await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        }
        await h.starter.awaitRunForTests()
        #expect(h.starter.state == .failed(.blockedByUpdater))
        #expect(h.failures == [.blockedByUpdater])
        #expect(h.log.count("start-runtime(kernel:false)") == 0)
    }

    @Test("延后中按按钮 → 取消等待、立刻重判")
    func buttonCutsDeferral() async {
        let h = Harness()
        h.arbiter.refuseLease = true
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        h.arbiter.refuseLease = false
        await h.press()
        #expect(h.log.count("start-runtime(kernel:true)") == 1)
        #expect(h.starter.state == .idle)
        // 旧的等待被取消，时间推过去也不会再起一次
        await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        await h.settle()
        #expect(h.log.count("start-runtime(kernel:false)") == 0)
    }

    @Test("状态序列：deferred → starting → idle（UI 唯一来源）")
    func stateSequence() async {
        let h = Harness()
        h.arbiter.refuseLease = true
        let gate = StepGate()
        h.commands.startGate.withLock { $0 = gate }
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        guard case .deferred = h.starter.state else {
            Issue.record("state = \(h.starter.state)")
            return
        }
        h.arbiter.refuseLease = false
        await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        await h.settle()
        #expect(h.starter.state == .starting)
        gate.open()
        await h.starter.awaitRunForTests()
        #expect(h.starter.state == .idle)
    }

    // MARK: 失败（不重试已失败的 system start）

    @Test("start 失败的三种结局 → failed + 启动路径通知一次，不重试", arguments: [
        (CommandOutcome.failed(exitCode: 1, detail: "boom"), RuntimeAutoStartFailure.commandFailed(exitCode: 1)),
        (.timedOut, .timedOut),
        (.notInstalled, .notInstalled),
    ])
    func startFailures(outcome: CommandOutcome, expected: RuntimeAutoStartFailure) async {
        let h = Harness(.init(start: outcome))
        await h.launch()
        #expect(h.starter.state == .failed(expected))
        #expect(h.failures == [expected])
        #expect(h.log.count("reconcile") == 0)
        #expect(h.log.count("start-runtime(kernel:false)") == 1)
        #expect(h.arbiter.held == nil)
        #expect(h.spy.events.last == .failed(.appLaunch, expected))
    }

    @Test("CLI 返回 0 但佐证探测不在 → notReady，不重试")
    func notReadyAfterStart() async {
        let h = Harness(.init(runningAfterStart: false))
        await h.launch()
        #expect(h.starter.state == .failed(.notReady))
        #expect(h.failures == [.notReady])
        #expect(h.log.count("reconcile") == 0)
    }

    @Test("按钮触发的失败只显示在横幅上，不发通知（用户就在看）")
    func buttonFailureDoesNotNotify() async {
        let h = Harness(.init(start: .timedOut))
        await h.press()
        #expect(h.starter.state == .failed(.timedOut))
        #expect(h.failures.isEmpty)
    }

    @Test("失败后按按钮成功 → 失败行消失")
    func retryClearsFailure() async {
        let h = Harness(.init(start: .timedOut))
        await h.launch()
        h.commands.script.withLock { $0.start = .succeeded }
        await h.press()
        #expect(h.starter.state == .idle)
    }

    @Test("在途时再按按钮 → 忽略（不并发起两次）")
    func buttonWhileStartingIsIgnored() async {
        let h = Harness()
        let gate = StepGate()
        h.commands.startGate.withLock { $0 = gate }
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        #expect(h.starter.state == .starting)
        h.starter.startNow()
        gate.open()
        await h.starter.awaitRunForTests()
        #expect(h.log.count("start-runtime(kernel:false)") + h.log.count("start-runtime(kernel:true)") == 1)
        // 在途的那一次没被作废：它的结果照常收尾（突变 M11：取消重来会让结果被丢弃、状态卡在延后、不 reconcile）。
        #expect(h.starter.state == .idle)
        #expect(h.log.count("reconcile") == 1)
    }

    // MARK: 退出交错（「await 本身就是窗口」）

    enum HangPoint: CaseIterable { case probe, lock, start }

    func install(_ gate: StepGate, on h: Harness, at point: HangPoint) {
        switch point {
        case .probe: h.commands.isRunningGate.withLock { $0 = gate }
        case .lock: h.commands.lockGate.withLock { $0 = gate }
        case .start: h.commands.startGate.withLock { $0 = gate }
        }
    }

    @Test("挂死在持租约的任一 await 上时退出 → beginTermination 同步归还租约", arguments: HangPoint.allCases)
    func terminationReleasesLeaseWhileHung(point: HangPoint) async {
        let h = Harness()
        let hang = StepGate(hangForever: true)
        install(hang, on: h, at: point)
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        #expect(hang.entered)
        #expect(h.arbiter.held != nil)

        h.starter.beginTermination()
        #expect(h.arbiter.held == nil)
    }

    @Test("await 期间开始退出、之后恢复 → 不 start / 不改状态 / 不通知 / 不 reconcile", arguments: HangPoint.allCases)
    func terminationDuringAwaitIsSilent(point: HangPoint) async {
        let h = Harness(.init(start: point == .start ? .timedOut : .succeeded))
        let pause = StepGate()
        install(pause, on: h, at: point)
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        #expect(pause.entered)
        let stateAtQuit = h.starter.state

        h.starter.beginTermination()
        pause.open()
        await h.starter.awaitRunForTests()

        #expect(h.starter.state == stateAtQuit)
        #expect(h.failures.isEmpty)
        #expect(h.log.count("reconcile") == 0)
        if point != .start {
            #expect(h.log.count("start-runtime(kernel:false)") == 0)
        }
        #expect(h.arbiter.held == nil)
    }

    @Test("延后等待中退出 → 不再醒来重判")
    func terminationDuringDeferral() async {
        let h = Harness()
        h.arbiter.refuseLease = true
        h.starter.startOnLaunchIfNeeded()
        await h.settle()
        h.starter.beginTermination()
        h.arbiter.refuseLease = false
        await h.clock.advance(by: RuntimeAutoStarter.retryInterval)
        await h.starter.awaitRunForTests()
        #expect(h.log.all.isEmpty)
    }

    // MARK: 偏好

    @Test("开关写入即落盘；退出开始之后不写")
    func togglePersists() {
        let h = Harness()
        h.starter.isEnabled = false
        #expect(h.prefs.isEnabled == false)
        h.starter.beginTermination()
        h.starter.isEnabled = true
        #expect(h.prefs.isEnabled == false)
    }

    @Test("UserDefaults 偏好：缺省为开；写入读回")
    func userDefaultsPreferences() throws {
        let suite = "cof-autostart-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = UserDefaultsRuntimeAutoStartPreferences(defaults: defaults)
        #expect(prefs.isEnabled)
        prefs.isEnabled = false
        #expect(UserDefaultsRuntimeAutoStartPreferences(defaults: defaults).isEnabled == false)
    }
}
