import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 评审 R6（R5 收尾增量）Claude 侧 Opus 对抗评审者的发现，探针转正（scratchpad `r6probe/`）。
/// 同一类病：非 committed 的 await 之后不查取消，退出已经放行，仍去写义务 / 状态 / 发通知。
@MainActor
@Suite("RuntimeUpdateStore R6：raced 分支与恢复收尾的 await 之后也要查取消")
struct RuntimeUpdateStoreR6Tests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    @Test("raced、驱动器没看到 ready（非 committed）、运行时在跑：退出落在列欠账的 ls 里 → 不改义务、不写状态")
    func quitDuringRacedOwedListKeepsObligation() async throws {
        let h = try Harness(
            callsReady: false, outcome: .finished(.raced, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: [])
        )
        let onDisk = T.intent(stopIssued: true)                    // 继承来的义务（R2 E）
        h.prefs.intent = onDisk
        let store = h.store
        h.commands.onList.withLock { $0 = { @Sendable n in
            guard n == 1 else { return }
            let committed = await store.isInCommittedPhase
            #expect(!committed)
            await store.prepareForTermination()
        } }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("ls") == 1)                            // 取消确实卡进了那个 await
        // 这次升级一开始就写了一份继承旧义务的新记录（R2 E，nonce 不同）：断言的是义务还在盘上、没被解除 / 清掉。
        #expect(h.prefs.intent?.owesRuntimeStart == true)
        #expect(h.prefs.intent?.runningContainerIDs == onDisk.runningContainerIDs)
        guard case .updating = h.store.state else {
            Issue.record("state rewritten after quit: \(h.store.state)"); return
        }
    }

    @Test("恢复：起运行时失败、义务留着；退出落在随后读版本的 await 里（committed 已结束）→ 不发「运行时停着」通知、不写状态")
    func quitDuringRecoveryVersionReadWritesNothing() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, running: [], start: .failed(exitCode: 1, detail: "x")))
        h.prefs.intent = T.intent(stopIssued: true)
        var notified = 0
        h.store.onRuntimeLeftStopped = { _, _ in notified += 1 }
        let store = h.store
        h.commands.onVersion.withLock { $0 = { @Sendable in
            let committed = await store.isInCommittedPhase
            #expect(!committed)                                     // committed 随 restore 的 defer 结束：退出取消我们、立即放行
            await store.prepareForTermination()
        } }
        await h.run { $0.recoverIfNeeded() }
        #expect(h.log.count("start-runtime") == 1)                 // 复原确实试过（committed 内）
        #expect(h.log.count("version") == 1)                       // 取消确实卡进了那个 await
        #expect(notified == 0)
        #expect(h.store.state == .recovering)
        #expect(h.prefs.intent?.owesRuntimeStart == true)          // 运行时还停着：义务留给下次启动
    }

    // MARK: - 3：退出开始之后不再开新操作（防御性：`.terminateLater` 期间 popover 是否还收事件未实测）

    @Test("退出开始之后：按钮消失；按钮 / 检查 / 立即更新 / 恢复 / 触发都不起新任务、不改 operation、不记待补的触发")
    func nothingStartsAfterTerminationBegins() async throws {
        let h = try Harness(script: .init(runtimeRunning: true, running: []))
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        h.store.activeIntent = T.intent(stopIssued: true)          // 会话内的义务：触发本会去探测
        #expect(h.store.manualRestore == .startRuntime)
        await h.store.prepareForTermination()
        #expect(h.store.manualRestore == nil)

        let op = h.store.operation
        h.store.startRuntime()
        h.store.checkForUpdates()
        h.store.automaticCheck()
        h.store.updateNow()
        h.store.recoverIfNeeded()
        h.store.runtimeMayHaveRestarted()
        h.store.skip(version: T.v150)                                // 写偏好：持久化动作，同样不接
        #expect(h.store.task == nil)
        #expect(h.store.operation == op)
        #expect(!h.store.restartCheckPending)
        #expect(h.prefs.skippedVersion == nil)
        #expect(!h.store.isAutomaticCheckDue())
        #expect(h.log.all.isEmpty)
    }

    @Test("退出时正忙（非 committed，被取消）：之后到达的触发不再记为待补")
    func triggerAfterTerminationIsNotRecorded() async throws {
        let h = try Harness()
        h.feed.gated.withLock { $0 = true }
        h.store.automaticCheck()
        #expect(h.store.isBusy)
        await h.store.prepareForTermination()
        h.store.runtimeMayHaveRestarted()
        #expect(!h.store.restartCheckPending)
        h.feed.release()
        await h.store.awaitOperationForTests()
    }

    /// committed 的升级：退出等它走完。期间 supervisor 的触发被 busy 挡下、记为待补；升级走完时 `operationEnded()` 不许在退出途中补做
    /// （那会在退出已经开始之后再起一次探测、改写状态）。
    @Test("committed 的升级在退出等待中走完：期间挡下的触发不在退出途中补做")
    func pendingTriggerIsNotReplayedDuringQuit() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: [], start: .failed(exitCode: 1, detail: "x")
        ))
        let store = h.store
        let commands = h.commands
        // 起运行时「失败」，但别人随即把它起来了：补做的探测若跑了，会把状态改写成「已更新」。
        h.commands.onStartRuntime.withLock { $0 = { @Sendable in commands.script.withLock { $0.runtimeRunning = true } } }
        let quitting = QuitBox()
        h.installer.afterReady.withLock { $0 = { @Sendable in
            await store.runtimeMayHaveRestarted()                   // busy ⇒ 记为待补
            quitting.start { await store.prepareForTermination() }  // committed ⇒ 退出等这次升级走完
        } }
        await h.run { $0.checkForUpdates() }
        await quitting.wait()
        #expect(h.store.state == .failed(
            .installedButNotRestarted(T.v150), pending: .runtimeStopped(because: .startFailed(.failed(exitCode: 1, detail: "x")))
        ))
    }

    /// codex R6 第 2 轮：`runtimeMayHaveRestarted` 起的确认任务不置 busy——原来的 `prepareForTermination` 只在 busy 时取消，于是它在退出后照样写。
    @Test("supervisor 触发的确认任务（不置 busy）在途时退出 → 被取消：不写日志、不改义务、不改状态")
    func inFlightConfirmationIsCancelledOnQuit() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        await h.run { $0.checkForUpdates() }                        // 升级失败、起运行时也失败 ⇒ 欠「起运行时」
        let stateBefore = h.store.state
        let intentBefore = h.prefs.intent
        #expect(intentBefore?.owesRuntimeStart == true)

        h.commands.script.withLock { $0.runtimeRunning = true }     // 用户在终端起了运行时；supervisor 的快照到达
        let gate = Gate()
        let entered = Mutex(false)
        h.commands.onIsRunning.withLock { $0 = { @Sendable _ in entered.withLock { $0 = true }; await gate.wait() } }
        h.store.runtimeMayHaveRestarted()
        while !entered.withLock({ $0 }) { await Task.yield() }
        #expect(!h.store.isBusy)
        await h.store.prepareForTermination()
        gate.open()
        await h.store.awaitOperationForTests()

        #expect(h.store.state == stateBefore)
        #expect(h.prefs.intent == intentBefore)
        let observed = h.updateLog.events.filter { if case .restored(_, _, .observedRunning, _, _) = $0 { true } else { false } }
        #expect(observed.isEmpty, "\(observed)")
    }

    // MARK: - 4：状态行（界面的第二个来源）不许在运行时起来之后一直说「运行时停着」

    @Test("已解除 → 用户停了运行时 → 按钮被锁挡住（状态行：运行时停着）→ 用户在终端起好运行时 → 触发 + 新鲜探测改写状态行")
    func staleRuntimeStoppedStatusLineIsRefreshed() async throws {
        let h = try await RuntimeUpdateStoreR5cTests.dischargedContainerDebt()
        h.commands.script.withLock { $0.runtimeRunning = false; $0.lockStates = [.running] }
        await h.run { $0.startRuntime() }
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .runtimeStopped(because: .anotherJobRunning)))

        h.commands.script.withLock { $0.runtimeRunning = true; $0.lockStates = [.idle] }
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .containersNotRestarted([RuntimeUpdateStoreR5cTests.buildkit])))
        #expect(h.store.manualRestore == .startRemainingContainers)
        #expect(h.log.count("start-runtime") == 1)                 // 只有升级那次失败的：触发只探测、不代为启动
    }

    @Test("已解除、状态行没说「运行时停着」→ 触发照旧不探测（放宽只针对那句会过期的话）")
    func dischargedTriggerWithoutStaleLineDoesNotProbe() async throws {
        let h = try await RuntimeUpdateStoreR5cTests.dischargedContainerDebt()
        let probes = h.log.count("is-running")
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.log.count("is-running") == probes)
    }

    // MARK: - 5a：启动恢复的准入闸

    @Test("启动恢复还没机会：盘上有义务也不显示按钮、按下无效")
    func manualRestoreWaitsForStartupRecovery() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, running: []))
        h.prefs.intent = T.intent(stopIssued: true)
        #expect(h.store.manualRestore == nil)
        h.store.startRuntime()
        #expect(h.store.task == nil)
        #expect(h.prefs.intent != nil)
    }

    /// 认领写在 `recoverIfNeeded` 所有 guard 之前：启动时盘上没有记录（最常见），恢复无事可做——本会话之后的升级留下的义务照样要有按钮。
    @Test("启动时无记录可恢复 → 之后本会话的升级留下义务，按钮照常出现（认领不依赖「有记录」）")
    func claimDoesNotDependOnARecord() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        h.store.recoverIfNeeded()                                  // 启动：盘上没有记录
        await h.run { $0.checkForUpdates() }                       // 升级失败、起运行时也失败 ⇒ 欠「起运行时」
        #expect(h.store.manualRestore == .startRuntime)
    }

    // MARK: - 8：锁忙路径被取消后不写 `restored` 审计日志

    @Test("锁忙（非 committed）时退出，取消落在 held() 的 await 里 → 不写 restored 审计日志", arguments: RuntimeUpdateStoreR5cTests.Path.allCases, RuntimeUpdateStoreR5cTests.Window.allCases)
    func cancelledInsideHeldLogsNothing(path: RuntimeUpdateStoreR5cTests.Path, window: RuntimeUpdateStoreR5cTests.Window) async throws {
        let lock: PrivilegedJobState = path == .manualStart ? .running : .probeFailed(5)
        let h = try Harness(script: .init(runtimeRunning: window == .containerList, running: [], lockStates: [lock]))
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        let store = h.store
        let quit: @Sendable (Int) async -> Void = { n in if n == 1 { await store.prepareForTermination() } }
        switch window {
        case .runtimeProbe: h.commands.onIsRunning.withLock { $0 = quit }
        case .containerList: h.commands.onList.withLock { $0 = quit }
        }
        switch path {
        case .manualStart: h.store.startRuntime()
        case .recovery: h.store.recoverIfNeeded()
        }
        await h.store.awaitOperationForTests()
        let restored = h.updateLog.events.filter { if case .restored = $0 { true } else { false } }
        #expect(restored.isEmpty, "\(restored)")
    }
}

/// 在 `@Sendable` 钩子里起一个退出任务、之后等它（钩子本身不能 await 它：committed 时退出要等的正是钩子所在的这次升级）。
final class QuitBox: @unchecked Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    func start(_ body: @escaping @Sendable () async -> Void) { task.withLock { $0 = Task { await body() } } }
    func wait() async { await task.withLock({ $0 })?.value }
}
