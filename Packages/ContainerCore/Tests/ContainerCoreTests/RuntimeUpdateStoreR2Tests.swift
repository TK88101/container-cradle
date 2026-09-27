import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 手动开闸：在某一步卡住 fake，制造「窗口」。
final class Gate: @unchecked Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// 评审 R2（Plan 附录 B）落到状态机上的修复。
@MainActor
@Suite("RuntimeUpdateStore R2：raced 按客观状态、ready 与退出的竞态、复原义务的继承、恢复的退出与 TOCTOU")
struct RuntimeUpdateStoreR2Tests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    static let buildkit = ContainerID("buildkit")!
    static let openConnector = ContainerID("open-connector")!

    // MARK: - A：raced 不再推断「运行时被别人起来了」

    /// 一个 `container system logs -f`（不依赖 apiserver）或只读 mmap 就会让装后复查报 raced——运行时其实停着。
    @Test("raced 且运行时停着 → 照常复原运行时与容器（不再丢在停止态）")
    func racedWithRuntimeStoppedRestores() async throws {
        let h = try Harness(
            outcome: .finished(.raced, blockers: ["/usr/local/bin/container"], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.racedDuringInstall(blockers: ["/usr/local/bin/container"]), pending: nil))
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
    }

    /// R3 P2-4（codex 更简方案）：运行时已被别人起来——不代为启动、不自动补拉容器（状态可疑，不叠加副作用），
    /// 但义务**不清**：容器欠账留给「启动运行时」（运行时在跑时它只拉容器）与下次启动的恢复流程，不静默丢掉。
    @Test("raced 且运行时已被别人起来 → 不代为启动、不自动补拉容器；欠账如实列出、只在本次会话，手动一按只拉回容器")
    func racedWithRuntimeRunningKeepsObligation() async throws {
        let h = try Harness(
            outcome: .finished(.raced, blockers: ["/usr/local/bin/container-apiserver"], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        h.startupRecoveryHadItsChance()
        let commands = h.commands
        h.installer.afterReady.withLock { $0 = { @Sendable in commands.script.withLock { $0.runtimeRunning = true } } }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(
            .racedDuringInstall(blockers: ["/usr/local/bin/container-apiserver"]),
            pending: .containersNotRestarted([Self.buildkit])
        ))
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("start:buildkit") == 0)
        #expect(h.prefs.intent == nil)              // 纯容器欠账只活在本次会话（R4 E）
        #expect(h.store.canStartRuntime)

        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == 0)   // 运行时在跑：不再 start
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
    }

    // MARK: - D：驱动器读到 ready 后跳回 MainActor 的那一跳，可以排在退出之后

    @Test("退出时 ready 那一跳还在路上 → handleReady 查到取消，不停运行时")
    func quitWhileReadyHopInFlight() async throws {
        let h = try Harness(outcome: .finished(.stopTimeout, blockers: [], details: []), script: .init(runtimeRunning: true))
        let gate = Gate()
        h.installer.beforeReady.withLock { $0 = { @Sendable in await gate.wait() } }
        h.store.checkForUpdates()
        while h.log.count("authorize") == 0 { await Task.yield() }
        #expect(!h.store.isInCommittedPhase)
        await h.store.prepareForTermination()   // preparing 阶段：取消后立即放行
        gate.open()                             // 那一跳这时才到
        await h.store.awaitOperationForTests()
        #expect(h.log.count("stop") == 0)
        #expect(h.log.count("ready") == 1)
    }

    // MARK: - E：未解决的复原义务不许被覆盖

    @Test("运行时被留在停止态后「检查更新」覆盖了失败态 →「启动运行时」仍可用，且真能起、拉回容器")
    func startRuntimeSurvivesStateOverwrite() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"],
            start: .failed(exitCode: 1, detail: "x")
        ))
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        guard case .failed(.installedButNotRestarted(T.v150), .runtimeStopped(because: .startFailed)?) = h.store.state else {
            Issue.record("expected leftStopped, got \(h.store.state)"); return
        }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .upToDate(T.v150))
        #expect(h.store.canStartRuntime)

        h.commands.script.withLock { $0.start = .succeeded }
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == 2)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
        #expect(!h.store.canStartRuntime)
    }

    @Test("install-failed 且起不来 → 再升级一次成功：新任务继承复原义务，起运行时、拉回升级前的容器")
    func reinstallInheritsRestoreObligation() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"],
            start: .failed(exitCode: 1, detail: "x")
        ))
        h.installer.queuedOutcomes.withLock { $0 = [.finished(.installFailed, blockers: [], details: [])] }
        await h.run { $0.checkForUpdates() }
        guard case .failed(.installFailed, .runtimeStopped?) = h.store.state else {
            Issue.record("expected leftStopped, got \(h.store.state)"); return
        }

        h.commands.script.withLock { $0.start = .succeeded }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.log.count("stop") == 1)            // 第二次时运行时本就停着，不再 stop
        #expect(h.log.count("start-runtime") == 2)   // 第一次失败的那次 + 这次
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
    }

    @Test("带着继承义务的新任务：一开始就把义务落盘（崩在 ready 之前，下次启动照样复原）")
    func inheritedObligationIsPersistedBeforeReady() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, running: []))
        h.prefs.intent = T.intent(stopIssued: true)
        let prefs = h.prefs
        let seen = Mutex<UpdateIntent?>(nil)
        h.installer.beforeReady.withLock { $0 = { @Sendable in
            let intent = await MainActor.run { prefs.intent }
            seen.withLock { $0 = intent }
        } }
        await h.run { $0.checkForUpdates() }
        let persisted = try #require(seen.withLock { $0 })
        #expect(persisted.stopIssued && persisted.runtimeWasRunning)
        #expect(persisted.runningContainerIDs == [Self.buildkit, Self.openConnector])
        #expect(persisted.target == T.v150)
    }

    @Test("带着继承义务的新任务在密码框被取消 → 义务保留、「启动运行时」仍可用，不擅自起运行时")
    func cancelKeepsInheritedObligation() async throws {
        let h = try Harness(callsReady: false, outcome: .cancelled, script: .init(runtimeRunning: false, running: []))
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .cancelled)
        #expect(h.prefs.intent?.stopIssued == true)
        #expect(h.prefs.intent?.runningContainerIDs == [Self.buildkit, Self.openConnector])
        #expect(h.store.canStartRuntime)
        #expect(h.log.count("start-runtime") == 0)
    }

    @Test("继承时冻结白名单取这一次停机时的最新值（不并入旧的），容器快照取并集")
    func inheritanceUsesFreshWhitelist() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, running: []), managed: ["buildkit"])
        h.prefs.intent = T.intent(stopIssued: true)   // 旧：running = [buildkit, open-connector]，managed = [open-connector]
        let prefs = h.prefs
        let atStop = Mutex<UpdateIntent?>(nil)
        h.installer.afterReady.withLock { $0 = { @Sendable in
            let intent = await MainActor.run { prefs.intent }
            atStop.withLock { $0 = intent }
        } }
        await h.run { $0.checkForUpdates() }
        let intent = try #require(atStop.withLock { $0 })
        #expect(intent.managedContainerIDs == [Self.buildkit])
        #expect(intent.runningContainerIDs == [Self.buildkit, Self.openConnector])
        // 复原时 buildkit 归 supervisor（最新白名单），open-connector 归升级器
        #expect(h.log.count("start:open-connector") == 1)
        #expect(h.log.count("start:buildkit") == 0)
    }

    // MARK: - L：只有真在复原运行时才算 committed

    @Test("恢复流程在等锁 → 不算 committed：退出立即放行，记录留着下次再恢复")
    func recoveringWhileWaitingForLockIsNotCommitted() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, lockStates: [.running]))
        h.prefs.intent = T.intent(stopIssued: true)
        h.store.recoverIfNeeded()
        #expect(h.store.state == .recovering)
        #expect(!h.store.isInCommittedPhase)
        await h.store.prepareForTermination()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent != nil)
        // 取消之后不再探锁：生产时钟的 sleep 被取消后立即返回，不查取消就会在退出途中连起几百个 lockf 进程。
        #expect(h.log.count("lock") <= 1)
    }

    @Test("恢复流程真在起运行时 → 算 committed（退出要等它）")
    func recoveringWhileStartingRuntimeIsCommitted() async throws {
        let h = try Harness(script: .init(installed: .installed(T.v150), runtimeRunning: false))
        h.prefs.intent = T.intent(stopIssued: true)
        let store = h.store
        let seen = Mutex<Bool?>(nil)
        h.commands.onStartRuntime.withLock { $0 = { @Sendable in
            let committed = await MainActor.run { store.isInCommittedPhase }
            seen.withLock { $0 = committed }
        } }
        await h.run { $0.recoverIfNeeded() }
        #expect(seen.withLock { $0 } == true)
    }

    // MARK: - O：拿不到实例租约的实例只读

    @Test("非主实例：不恢复、不检查、不到期、不给「启动运行时」——哪怕 defaults 里有未解决的记录")
    func secondaryInstanceIsReadOnly() async throws {
        let h = try Harness(script: .init(runtimeRunning: false), primary: false)
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        #expect(h.store.state == .otherInstanceActive)

        await h.run { $0.recoverIfNeeded() }
        await h.run { $0.checkForUpdates() }
        await h.run { $0.automaticCheck() }
        await h.run { $0.updateNow() }
        await h.run { $0.startRuntime() }

        #expect(h.log.all.isEmpty)
        #expect(!h.store.isAutomaticCheckDue())
        #expect(!h.store.canStartRuntime)
        #expect(h.store.state == .otherInstanceActive)
        #expect(h.prefs.intent?.stopIssued == true)   // 别人的记录原样不动
    }

    // MARK: - M：恢复只读一次意图记录

    @Test("recoverIfNeeded 之后、任务开始之前记录被清 → 不会永远卡在 recovering")
    func recoveryDoesNotReReadIntent() async throws {
        let h = try Harness(script: .init(runtimeRunning: false))
        h.prefs.intent = T.intent(stopIssued: true)
        h.store.recoverIfNeeded()
        h.prefs.intent = nil
        await h.store.awaitOperationForTests()
        #expect(h.store.state != .recovering)
        #expect(!h.store.isBusy)
    }
}
