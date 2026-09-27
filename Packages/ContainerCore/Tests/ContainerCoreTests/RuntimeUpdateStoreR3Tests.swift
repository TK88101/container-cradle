import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 评审 R3（Plan 附录 B）落到状态机上的修复：复原前查锁、取消落在探锁的 await 里。
@MainActor
@Suite("RuntimeUpdateStore R3：复原前查锁、取消落在探锁里")
struct RuntimeUpdateStoreR3Tests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    // MARK: - P1-1：复原只在锁空闲时动手

    /// 带继承义务的新任务，root 结局 busy：别的 root 任务持着锁、可能正在替换二进制——此刻 system start = 新旧混跑。
    @Test("带继承义务的新任务结局 busy（别的 root 任务持锁）→ 不起运行时、不拉容器，义务留着")
    func busyWithInheritedObligationDoesNotRestore() async throws {
        let h = try Harness(
            callsReady: false, outcome: .finished(.busy, blockers: [], details: []),
            script: .init(runtimeRunning: false, running: [], lockStates: [.idle, .running])
        )
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("start:buildkit") == 0)
        #expect(h.store.state == .failed(.anotherJobRunning, pending: .runtimeStopped(because: .anotherJobRunning)))
        #expect(h.prefs.intent?.stopIssued == true)
        #expect(h.store.canStartRuntime)
    }

    // MARK: - R4（codex P2）

    @Test("复原前探锁本身失败 → 原因报 lockProbeFailed（不是「另一个升级在跑」），不起运行时、义务留着")
    func restoreLockProbeFailureIsReportedAsSuch() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"],
            lockStates: [.idle, .probeFailed(73)]
        ))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.installedButNotRestarted(T.v150), pending: .runtimeStopped(because: .lockProbeFailed(73))))
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent?.stopIssued == true)
    }

    @Test("升级成功 → 菜单里的已装版本立刻是新版本（不等下一次检查）")
    func successRefreshesInstalledVersion() async throws {
        let h = try Harness(script: .init(installedAfterInstall: .installed(T.v150), runtimeRunning: true))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.store.lastKnownInstalled == T.v150)
    }

    // MARK: - P2-1：取消落在探锁的 await 里

    @Test("恢复流程：取消落在探锁的 await 里 → 探锁返回空闲也不起运行时、不请 reconcile")
    func recoveryCancelledDuringLockProbe() async throws {
        let h = try Harness(script: .init(runtimeRunning: false))
        h.prefs.intent = T.intent(stopIssued: true)
        let gate = Gate()
        h.commands.onLockProbe.withLock { $0 = { @Sendable _ in await gate.wait() } }
        h.store.recoverIfNeeded()
        while h.commands.lockProbeCount.withLock({ $0 }) == 0 { await Task.yield() }
        #expect(!h.store.isInCommittedPhase)
        await h.store.prepareForTermination()
        gate.open()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("reconcile") == 0)
        #expect(h.prefs.intent != nil)
    }

    @Test("手动「启动运行时」：取消落在探锁的 await 里 → 不起运行时")
    func manualStartCancelledDuringLockProbe() async throws {
        let h = try Harness(script: .init(runtimeRunning: false))
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        let gate = Gate()
        h.commands.onLockProbe.withLock { $0 = { @Sendable _ in await gate.wait() } }
        h.store.startRuntime()
        while h.commands.lockProbeCount.withLock({ $0 }) == 0 { await Task.yield() }
        await h.store.prepareForTermination()
        gate.open()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent != nil)
    }

    /// 生产时钟的 sleep 被取消后立即返回：不查取消，退出途中会连起最多 720 个 lockf。
    @Test("收尾等锁（osascript 异常结束）时被取消 → 立即停止探锁")
    func waitForJobToEndStopsOnCancel() async throws {
        let h = try Harness(
            callsReady: false, outcome: .unknown("killed"),
            script: .init(runtimeRunning: true, lockStates: [.idle, .running])
        )
        let store = h.store
        h.commands.onLockProbe.withLock { $0 = { @Sendable n in
            if n == 2 { await store.prepareForTermination() }   // 此刻还在 preparing：退出会取消任务
        } }
        await h.run { $0.checkForUpdates() }
        #expect(h.commands.lockProbeCount.withLock { $0 } <= 3)
        #expect(h.log.count("start-runtime") == 0)
    }
}
