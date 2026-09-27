import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 评审 R7（R6 裁决落地的增量）codex 的发现：检查 / 升级的准备阶段（非 committed）被退出取消之后，还在往下走、写偏好、写状态、甚至开始下载。
@MainActor
@Suite("RuntimeUpdateStore R7：检查与升级准备阶段被退出取消后什么都不写、不再往下走")
struct RuntimeUpdateStoreR7Tests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    @Test("手动检查卡在 GitHub 请求时退出，请求忽略取消照常返回新版本 → 不写偏好、不改状态、不探锁、不下载")
    func quitDuringFeedWritesNothing() async throws {
        let h = try Harness()
        h.feed.gated.withLock { $0 = true }
        h.store.checkForUpdates()
        while h.log.count("feed") == 0 { await Task.yield() }
        await h.store.prepareForTermination()
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.prefs.lastSuccessfulCheck == nil)
        #expect(h.store.state == .checking)
        #expect(h.log.count("lock") == 0)
        #expect(h.log.count("download") == 0)
    }

    @Test("检查在读已装版本时退出 → 不再请求 GitHub")
    func quitDuringVersionReadDoesNotQueryFeed() async throws {
        let h = try Harness()
        let store = h.store
        h.commands.onVersion.withLock { $0 = { @Sendable in await store.prepareForTermination() } }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("version") == 1)
        #expect(h.log.count("feed") == 0)
        #expect(h.store.state == .checking)
    }

    @Test("下载成功、但下载期间已开始退出 → 不起校验（pkgutil 进程）")
    func quitDuringSuccessfulDownloadDoesNotVerify() async throws {
        let h = try Harness()
        let store = h.store
        h.downloader.hook.set { await store.prepareForTermination() }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("download") == 1)
        #expect(h.log.count("verify") == 0)
    }

    @Test("升级在探锁时退出（非 committed，被取消）→ 不下载")
    func quitDuringInstallLockProbeDoesNotDownload() async throws {
        let h = try Harness()
        let store = h.store
        h.commands.onLockProbe.withLock { $0 = { @Sendable n in if n == 1 { await store.prepareForTermination() } } }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("lock") == 1)
        #expect(h.log.count("download") == 0)
        guard case .updating = h.store.state else { Issue.record("state written after quit: \(h.store.state)"); return }
    }

    @Test("下载途中退出、下载因取消而失败 → 不写失败态")
    func quitDuringDownloadDoesNotWriteFailure() async throws {
        let h = try Harness(downloadFailure: .network("cancelled"))
        let store = h.store
        h.downloader.hook.set { await store.prepareForTermination() }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("download") == 1)
        guard case .updating = h.store.state else { Issue.record("state written after quit: \(h.store.state)"); return }
    }

    @Test("退出开始之后拨自动检查开关 → 不写偏好")
    func automaticCheckToggleIsIgnoredAfterTerminationBegins() async throws {
        let h = try Harness()
        #expect(h.store.isAutomaticCheckEnabled)
        await h.store.prepareForTermination()
        h.store.isAutomaticCheckEnabled = false
        #expect(h.prefs.isAutomaticCheckEnabled)
    }

    // MARK: - Opus R7（探针转正，scratchpad `r7probe/`）

    /// A：supervisor 连投两份带代号的快照 ⇒ 两个确认任务；退出只取消槽里那个，第一个成了孤儿、照写。
    @Test("两个确认任务同时在途时退出 → 两个都不写（确认任务单飞：起新的之前取消旧的）")
    func orphanConfirmationDoesNotWriteAfterQuit() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        await h.run { $0.checkForUpdates() }
        let stateBefore = h.store.state
        let intentBefore = h.prefs.intent
        #expect(intentBefore?.owesRuntimeStart == true)

        h.commands.script.withLock { $0.runtimeRunning = true }
        let gate = Gate()
        let entered = Mutex(0)
        h.commands.onIsRunning.withLock { $0 = { @Sendable _ in entered.withLock { $0 += 1 }; await gate.wait() } }
        h.store.runtimeMayHaveRestarted()
        let first = h.store.task
        while entered.withLock({ $0 }) < 1 { await Task.yield() }
        h.store.runtimeMayHaveRestarted()
        let second = h.store.task
        while entered.withLock({ $0 }) < 2 { await Task.yield() }
        #expect(first != second)
        #expect(!h.store.isBusy)

        await h.store.prepareForTermination()
        gate.open()
        await first?.value
        await second?.value
        let observed = h.updateLog.events.filter { if case .restored(_, _, .observedRunning, _, _) = $0 { true } else { false } }
        #expect(observed.isEmpty, "\(observed)")
        #expect(h.prefs.intent == intentBefore)
        #expect(h.store.state == stateBefore)
    }

    /// B：`nothingStartsAfterTerminationBegins` 里 state 是 idle，`install()` 在 switch 就 return——它自己那道闸从没被走到。
    @Test("可用更新摆着时退出 → install() / updateNow() 都不起任务")
    func installIsRefusedAfterTerminationBegins() async throws {
        let h = try Harness()
        await h.run { $0.automaticCheck() }
        guard case .available = h.store.state else { Issue.record("setup: \(h.store.state)"); return }
        await h.store.prepareForTermination()
        let op = h.store.operation
        h.store.install()
        h.store.updateNow()
        #expect(h.store.operation == op)
        #expect(h.log.count("download") == 0)
        guard case .available = h.store.state else { Issue.record("install started after quit: \(h.store.state)"); return }
    }

    final class Flag: @unchecked Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// 睡进去就永不返回、也不响应取消：没有「放手」能力的实现会把退出挂住，而不是变绿。
    struct ParkingClock: SupervisorClock {
        let parked: Flag
        func now() -> Date { Date(timeIntervalSince1970: 0) }
        func sleep(until deadline: Date) async {
            parked.set()
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
    }

    /// C：退出在 committed（installing）时开始等；osascript 随后没按契约结束，任务转进「等 root 结束」（不算 committed，R5 P2-3）——退出不能被它挡住。
    @Test("installing 时退出（等）→ osascript 异常结束 → 收尾等锁时锁仍被占：退出放行，不起运行时，义务在盘")
    func quitAlreadyWaitingIsReleasedWhenTaskTurnsToLockWait() async throws {
        let parked = Flag()
        let h = try Harness(
            outcome: .unknown("killed"),
            script: .init(runtimeRunning: true, running: [], lockStates: [.idle, .running]),
            clock: ParkingClock(parked: parked)
        )
        let store = h.store
        let quitStartedCommitted = Mutex<Bool?>(nil)
        let quitDone = Mutex(false)
        let quitting = QuitBox()
        h.installer.afterReady.withLock { $0 = { @Sendable in
            quitting.start { @MainActor in
                quitStartedCommitted.withLock { $0 = store.isInCommittedPhase }
                await store.prepareForTermination()
                quitDone.withLock { $0 = true }
            }
            while quitStartedCommitted.withLock({ $0 }) == nil { await Task.yield() }
        } }
        h.store.checkForUpdates()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !quitDone.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(quitStartedCommitted.withLock { $0 } == true)
        #expect(quitDone.withLock { $0 }, "退出被非 committed 的等锁挡住（parked=\(parked.isSet)）")
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent?.owesRuntimeStart == true)
    }

    /// E：确认之后什么都不欠了，状态行却还挂着手动启动时的阻挡原因。
    @Test("手动启动被锁挡住后，用户在终端起好运行时和容器 → 确认之后什么都不欠 → 回到空闲，不留过期的「另一个更新正在进行」")
    func resolvedBlockerDoesNotLingerInStatusLine() async throws {
        let h = try await RuntimeUpdateStoreR5cTests.dischargedContainerDebt()
        h.feed.result.withLock { $0 = .failed(.network("offline")) }
        await h.run { $0.checkForUpdates() }
        guard case .checkFailed = h.store.state else { Issue.record("setup: \(h.store.state)"); return }
        h.commands.script.withLock { $0.runtimeRunning = false; $0.lockStates = [.running] }
        await h.run { $0.startRuntime() }
        #expect(h.store.state == .failed(.anotherJobRunning, pending: .runtimeStopped(because: .anotherJobRunning)))
        h.commands.script.withLock { $0.runtimeRunning = true; $0.running = ["buildkit"]; $0.lockStates = [.idle] }
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.prefs.intent == nil)
        #expect(h.store.manualRestore == nil)
        #expect(h.store.state == .idle)
    }

    // MARK: - D：认领之前的检查把启动恢复挡掉 → 检查结束后补做

    static func startupLifecycle(_ h: Harness, gate: Gate, loaded: Flag) -> AppLifecycle {
        let store = h.store
        return AppLifecycle(steps: .init(
            beginStartup: {},
            startSupervisor: {},
            loadWhitelist: { loaded.set(); await gate.wait() },
            beginBackgroundWork: { store.recoverIfNeeded() },
            prepareForQuit: { await store.prepareForTermination() },
            stopSupervisor: {}
        ))
    }

    @Test("冷启动卡在读白名单时用户点了「检查更新」，恢复到达时被 busy 挡掉 → 检查结束后恢复照常补做")
    func startupRecoveryDeferredBehindCheckRunsAfterIt() async throws {
        let h = try Harness(feed: .failed(.network("offline")), script: .init(runtimeRunning: false, running: []))
        h.prefs.intent = T.intent(stopIssued: true)
        h.installer.stateFile.withLock { $0 = .done(.installFailed) }
        let gate = Gate()
        let loaded = Flag()
        let lifecycle = Self.startupLifecycle(h, gate: gate, loaded: loaded)
        h.feed.gated.withLock { $0 = true }
        let starting = Task { await lifecycle.start() }
        while !loaded.isSet { await Task.yield() }
        h.store.checkForUpdates()
        gate.open()
        await starting.value
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.store.state == .failed(.installFailed(details: []), pending: nil))
    }

    /// 升级之后义务仍留在盘上（起运行时失败）——但那是本会话写的新记录（新 nonce），不是恢复当时被挡掉的那一份。
    @Test("被挡掉的恢复在检查转成升级时不补做：升级已把旧义务继承进本会话的新记录（新 nonce）")
    func deferredRecoveryIsDroppedWhenInstallTakesOverObligation() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: false, running: [], start: .failed(exitCode: 1, detail: "x")
        ))
        let old = T.intent(stopIssued: true)
        h.prefs.intent = old
        let gate = Gate()
        let loaded = Flag()
        let lifecycle = Self.startupLifecycle(h, gate: gate, loaded: loaded)
        h.feed.gated.withLock { $0 = true }
        let starting = Task { await lifecycle.start() }
        while !loaded.isSet { await Task.yield() }
        h.store.checkForUpdates()                                   // 手动：查到就装
        gate.open()
        await starting.value
        h.feed.release()
        await h.store.awaitOperationForTests()
        let recovering = h.updateLog.events.filter { if case .recovering = $0 { true } else { false } }
        #expect(recovering.isEmpty, "\(recovering)")
        #expect(h.log.count("authorize") == 1)
        #expect(h.prefs.intent != nil && h.prefs.intent?.nonce != old.nonce)   // 盘上是本会话的新记录
    }

    @Test("被挡掉的恢复：检查结束时已在退出 → 不补做")
    func deferredRecoveryIsNotRunAfterTerminationBegins() async throws {
        let h = try Harness(feed: .failed(.network("offline")), script: .init(runtimeRunning: false, running: []))
        h.prefs.intent = T.intent(stopIssued: true)
        h.feed.gated.withLock { $0 = true }
        h.store.checkForUpdates()
        h.store.recoverIfNeeded()                                   // 被 busy 挡掉 ⇒ 记下
        await h.store.prepareForTermination()                       // 检查被取消
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("lock") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent != nil)
    }

    /// codex R7：补恢复与待补的重启确认同时存在 ⇒ 先恢复（它会置 activeIntent）、恢复结束后才确认。反过来确认会因为还没有会话内义务而空转、把待补的触发吃掉。
    @Test("被挡掉的恢复与被挡掉的重启确认同时待补 → 先恢复、恢复结束后才做确认")
    func deferredRecoveryRunsBeforePendingConfirmation() async throws {
        let h = try Harness(feed: .failed(.network("offline")), script: .init(runtimeRunning: false, running: [], start: .failed(exitCode: 1, detail: "x")))
        h.prefs.intent = T.intent(stopIssued: true)
        let commands = h.commands
        // 恢复起运行时「失败」，但别人随即把它起来了：之后的确认会看到它在跑。
        h.commands.onStartRuntime.withLock { $0 = { @Sendable in commands.script.withLock { $0.runtimeRunning = true } } }
        h.feed.gated.withLock { $0 = true }
        h.store.checkForUpdates()
        h.store.recoverIfNeeded()                                   // 被 busy 挡掉 ⇒ 记下恢复
        h.store.runtimeMayHaveRestarted()                           // 被 busy 挡掉 ⇒ 记下确认
        #expect(h.store.restartCheckPending)
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 1)                 // 恢复跑了
        let observed = h.updateLog.events.filter { if case .restored(_, _, .observedRunning, _, _) = $0 { true } else { false } }
        #expect(observed.count == 1, "\(h.updateLog.events)")      // 恢复之后确认也跑了
    }
}
