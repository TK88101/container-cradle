import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 评审 R4（Plan 附录 B）落到状态机上的修复：取消落在收尾等锁里、复原欠账如实说明、义务拆成「起运行时 / 拉容器」、
/// committed 覆盖到 reconcile 请求。
@MainActor
@Suite("RuntimeUpdateStore R4：欠账如实说明、陈旧义务、reconcile 请求的退出窗口")
struct RuntimeUpdateStoreR4Tests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    // MARK: - A：收尾等锁的探锁返回空闲之后才被取消

    @Test("unknown 未到 ready + 继承义务：退出落在收尾等锁的探锁里 → 不起运行时、不写状态、义务留着")
    func cancelledDuringWaitForJobToEndDoesNotStart() async throws {
        let h = try Harness(
            callsReady: false, outcome: .unknown("killed"),
            script: .init(runtimeRunning: false, running: [], lockStates: [.idle, .idle, .idle])
        )
        h.prefs.intent = T.intent(stopIssued: true)
        let store = h.store
        let committedAtCancel = Mutex<Bool?>(nil)
        h.commands.onLockProbe.withLock { $0 = { @Sendable n in
            guard n == 2 else { return }   // 第 1 次是装前探锁；第 2 次是收尾等锁
            let committed = await store.isInCommittedPhase
            committedAtCancel.withLock { $0 = committed }
            await store.prepareForTermination()
        } }
        var notified = 0
        h.store.onRuntimeLeftStopped = { _, _ in notified += 1 }
        await h.run { $0.checkForUpdates() }
        #expect(committedAtCancel.withLock { $0 } == false)
        #expect(h.log.count("start-runtime") == 0)
        #expect(notified == 0)
        #expect(h.prefs.intent?.stopIssued == true)
    }

    // MARK: - B：装上了，只是复原被锁挡住

    @Test("installed 但复原时锁被别的任务持有 → 已装版本刷新为新版本，义务留着")
    func installedButRestoreBlockedRefreshesVersion() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"],
            lockStates: [.idle, .running]
        ))
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        #expect(h.store.lastKnownInstalled == T.v150)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent?.stopIssued == true)
        #expect(h.store.canStartRuntime)
    }

    // MARK: - C：手动「启动运行时」被锁挡住不再静默

    @Test("手动启动运行时遇锁忙 → 状态说明原因（不静默回原态），义务留着")
    func manualStartBlockedIsNotSilent() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        let before = h.store.state
        h.commands.script.withLock { $0.start = .succeeded; $0.lockStates = [.running] }
        await h.run { $0.startRuntime() }
        #expect(h.store.state != before)
        // 精确到原因（R5 P2-6：`!= before` 连「静默回到 idle」都放行）：保留原失败文案，欠账的原因换成锁。
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .runtimeStopped(because: .anotherJobRunning)))
        #expect(h.log.count("start-runtime") == 1)   // 只有升级那次失败的
        #expect(h.store.canStartRuntime)
    }

    // MARK: - D：锁被占着、运行时其实在跑

    @Test("恢复流程复原时锁忙、运行时在跑 → 不报「运行时停着」、不发通知")
    func recoveryBlockedWhileRuntimeRunningDoesNotClaimStopped() async throws {
        let h = try Harness(script: .init(runtimeRunning: true, running: [], lockStates: [.idle, .running]))
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        var notified = 0
        h.store.onRuntimeLeftStopped = { _, _ in notified += 1 }
        await h.run { $0.recoverIfNeeded() }
        #expect(notified == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.store.canStartRuntime)
    }

    @Test("冷启动恢复被锁挡住 → 之后手动「启动运行时」也请受管 reconcile（supervisor 冷启动走 baseline，不会自己拉）")
    func manualStartAfterBlockedRecoveryRequestsReconcile() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, running: [], lockStates: [.idle, .running]))
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        await h.run { $0.recoverIfNeeded() }
        #expect(h.log.count("reconcile") == 0)
        h.commands.script.withLock { $0.lockStates = [.idle] }
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.log.count("reconcile") == 1)
        #expect(h.prefs.intent == nil)
    }

    // MARK: - E：raced 且运行时在跑 → 纯容器欠账不跨重启

    @Test("raced 且运行时在跑 → 容器欠账只活在本次会话：defaults 不留记录；重启 App（运行时停着）不起运行时、不拉容器")
    func racedWithRuntimeRunningDoesNotOutliveSession() async throws {
        let h = try Harness(
            outcome: .finished(.raced, blockers: ["/usr/local/bin/container-apiserver"], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        h.startupRecoveryHadItsChance()
        let commands = h.commands
        h.installer.afterReady.withLock { $0 = { @Sendable in commands.script.withLock { $0.runtimeRunning = true } } }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.canStartRuntime)            // 本次会话里「启动运行时」仍可拉回容器
        // 盘上没有记录 ⇒ 重启 App 之后恢复流程无事可做（R5 P2-7：原来的「重启后」半段注入的就是 nil，恒真，删掉）。
        #expect(h.prefs.intent == nil)
    }

    // MARK: - G：请 supervisor reconcile 还在路上时退出

    @Test("恢复流程起完运行时、请 reconcile 还在路上 → 仍算 committed（退出等它送达），记录在请求之后才清")
    func recoveryStaysCommittedUntilReconcileRequested() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, running: [], lockStates: [.idle]))
        h.prefs.intent = T.intent(stopIssued: true)
        h.installer.stateFile.withLock { $0 = .done(.installed) }
        let store = h.store
        let prefs = h.prefs
        let committed = Mutex<Bool?>(nil)
        let intentPresent = Mutex<Bool?>(nil)
        h.reconcileHook.set { @Sendable in
            let c = await store.isInCommittedPhase
            let p = await prefs.intent != nil
            committed.withLock { $0 = c }
            intentPresent.withLock { $0 = p }
        }
        await h.run { $0.recoverIfNeeded() }
        #expect(committed.withLock { $0 } == true)
        #expect(intentPresent.withLock { $0 } == true)
        #expect(h.log.count("reconcile") == 1)
        #expect(h.prefs.intent == nil)
    }
}
