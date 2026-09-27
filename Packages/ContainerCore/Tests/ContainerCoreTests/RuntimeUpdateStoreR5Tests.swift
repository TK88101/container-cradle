import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 评审 R5（R4 增量的对抗评审）落到状态机上的修复。探针来自评审者（scratchpad `r5probe/`），这里转正。
@MainActor
@Suite("RuntimeUpdateStore R5：冷启动触发不抢恢复、被 busy 挡掉的触发会补做、收尾等锁不算 committed")
struct RuntimeUpdateStoreR5Tests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    static let buildkit = ContainerID("buildkit")!
    static let openConnector = ContainerID("open-connector")!

    // MARK: - P1-1：冷启动时 supervisor 的首份快照先于 recoverIfNeeded 到达

    /// `AppModel.start()`：`await supervisor.start()` 的首轮探测投出的快照，其 MainActor 任务排在 `start()` 的续体之前——
    /// 触发先到、恢复后到。落盘义务归恢复流程：触发不许抢先把它「解除」并清掉。
    @Test("冷启动：触发先于恢复到达 → 恢复照常跑完（拉未受管、请受管 reconcile、报状态文件的结论）")
    func coldStartTriggerDoesNotPreemptRecovery() async throws {
        let h = try Harness(script: .init(installed: .installed(T.v150), runtimeRunning: true, running: []))
        h.prefs.intent = T.intent(stopIssued: true)            // buildkit（未受管）+ open-connector（受管）
        h.installer.stateFile.withLock { $0 = .done(.installed) }
        await h.run { $0.runtimeMayHaveRestarted() }            // 首份快照先到
        #expect(h.prefs.intent?.owesRuntimeStart == true)
        await h.run { $0.recoverIfNeeded() }                    // start() 恢复之后
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.log.count("reconcile") == 1)
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.prefs.intent == nil)
    }

    // MARK: - P2-1：busy 时被挡掉的触发会在操作结束后补做

    @Test("busy 时的触发不丢：操作结束后补做一次新鲜探测（supervisor 只在状态变化时投快照，挡掉的不会再来）")
    func droppedTriggerIsRetriedAfterOperation() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        #expect(h.prefs.intent?.owesRuntimeStart == true)

        h.feed.result.withLock { $0 = .failed(.network("offline")) }
        h.feed.gated.withLock { $0 = true }
        h.store.automaticCheck()
        h.commands.script.withLock { $0.runtimeRunning = true }   // 用户在终端起了运行时；快照此刻到达
        let probesBefore = h.log.count("is-running")
        h.store.runtimeMayHaveRestarted()
        while h.log.count("feed") < 2 { await Task.yield() }
        #expect(h.log.count("is-running") == probesBefore)       // busy 期间不探测
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("is-running") == probesBefore + 1)   // 结束后补做了一次
        #expect(h.prefs.intent == nil)                            // 起运行时义务解除（纯容器欠账只在会话里）
        #expect(h.store.canStartRuntime)

        // 之后用户有意停了运行时、App 重启：不许替他起。
        let h2 = try Harness(script: .init(runtimeRunning: false, running: []))
        h2.startupRecoveryHadItsChance()
        h2.prefs.intent = h.prefs.intent
        await h2.run { $0.recoverIfNeeded() }
        #expect(h2.log.count("start-runtime") == 0)
    }

    // MARK: - P2-2：ready 之后收尾等锁不算 committed

    @Test("ready 之后 osascript 异常结束、等 root 任务结束的这段 → 不算 committed：退出放行，不起运行时，义务落盘")
    func lockWaitAfterUnexpectedEndIsNotCommitted() async throws {
        let h = try Harness(outcome: .unknown("killed"), script: .init(runtimeRunning: true, running: [], lockStates: [.idle, .running]))
        let store = h.store
        let committed = Mutex<Bool?>(nil)
        h.commands.onLockProbe.withLock { $0 = { @Sendable n in
            guard n == 2 else { return }                           // 第 2 次 = 收尾等锁
            let c = await store.isInCommittedPhase
            committed.withLock { $0 = c }
            if !c { await store.prepareForTermination() }         // committed 时调它会等自己 = 死锁；只记录
        } }
        await h.run { $0.checkForUpdates() }
        #expect(committed.withLock { $0 } == false)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent?.owesRuntimeStart == true)          // stop 已发、记录在盘：下次启动恢复
    }

    // MARK: - P2-3：被取消的任务在 root 结束后不再复原

    @Test("密码框期间退出（任务被取消）、之后 root 才以 finished 结束 → 不写状态、不起运行时，义务留给下次启动")
    func cancelledTaskDoesNotRestoreOnFinished() async throws {
        let h = try Harness(
            callsReady: false, outcome: .finished(.stopTimeout, blockers: [], details: []),
            script: .init(runtimeRunning: false, running: [])
        )
        h.prefs.intent = T.intent(stopIssued: true)
        let store = h.store
        h.installer.beforeReady.withLock { $0 = { @Sendable in await store.prepareForTermination() } }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("start:buildkit") == 0)
        #expect(h.prefs.intent?.owesRuntimeStart == true)
    }

    @Test("raced 结局、ready 没被看到（仍非 committed）：退出落在「运行时在不在跑」的读里 → 不复原、不写状态")
    func quitDuringRacedRuntimeCheckDoesNotRestore() async throws {
        let h = try Harness(
            callsReady: false, outcome: .finished(.raced, blockers: [], details: []),
            script: .init(runtimeRunning: false, running: [])
        )
        h.prefs.intent = T.intent(stopIssued: true)
        let store = h.store
        h.commands.onIsRunning.withLock { $0 = { @Sendable n in if n == 1 { await store.prepareForTermination() } } }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent?.owesRuntimeStart == true)
    }

    // MARK: - P2-4：reconcile 请求超时时，欠账对照此刻在跑的容器

    @Test("reconcile 请求超时、但受管容器其实在跑 → 不列为欠账；都在跑 ⇒ 什么都不欠")
    func reconcileTimeoutOnlyListsNotRunning() async throws {
        let h = try Harness(
            script: .init(installed: .installed(T.v150), runtimeRunning: true, running: ["open-connector"]),
            reconcileLimit: .milliseconds(50)
        )
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        h.installer.stateFile.withLock { $0 = .done(.installed) }
        h.reconcileHook.set { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
        await h.run { $0.recoverIfNeeded() }
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.prefs.intent == nil)
        #expect(!h.store.canStartRuntime)
    }

    // MARK: - P2-8：解除之后没有欠账的「装上了」就是成功

    @Test("「装上了、运行时停着」之后用户手动起了运行时且什么都不欠 → 显示成功，不留红色失败态")
    func installedAndDischargedWithoutDebtIsSuccess() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: [], start: .failed(exitCode: 1, detail: "x")
        ))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.installedButNotRestarted(T.v150), pending: .runtimeStopped(because: .startFailed(.failed(exitCode: 1, detail: "x")))))
        h.commands.script.withLock { $0.runtimeRunning = true }
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.prefs.intent == nil)
        guard case .restored(_, false, .observedRunning, nil, 0) = h.updateLog.events.last else {
            Issue.record("last log event: \(String(describing: h.updateLog.events.last))"); return
        }
    }

    @Test("startDischarged 往返编码保持 true（旧记录兼容之外，新字段本身也得读得回来）")
    func startDischargedRoundTrips() throws {
        var intent = T.intent(stopIssued: true)
        intent.startDischarged = true
        let decoded = try JSONDecoder().decode(UpdateIntent.self, from: JSONEncoder().encode(intent))
        #expect(decoded == intent)
        #expect(decoded.startDischarged)
        #expect(!decoded.owesRuntimeStart)
    }
}
