import Foundation
import Testing

@testable import ContainerCore

/// codex 对 R5 的补评（附录 B「codex 补评」）落到状态机上的修复。
@MainActor
@Suite("RuntimeUpdateStore R5 补评：锁忙路径（非 committed）的取消在 held() 的 await 之后也要查")
struct RuntimeUpdateStoreR5cTests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    static let buildkit = ContainerID("buildkit")!

    enum Path: String, CaseIterable, Sendable {
        case manualStart
        case recovery
    }

    /// `held()` 里的两个 await：问运行时在不在跑（此时它停着 ⇒ 否则会报「运行时停着」并发通知）/ 列在跑的容器（它在跑 ⇒ 否则会把义务改成
    /// 会话内的容器欠账、从磁盘上清掉）。
    enum Window: String, CaseIterable, Sendable {
        case runtimeProbe
        case containerList
    }

    @Test(
        "锁忙（不算 committed）时退出，取消落在 held() 的 await 里 → 不写状态、不发通知、记录原样留给下次启动",
        arguments: Path.allCases, Window.allCases
    )
    func cancelledInsideHeldWritesNothing(path: Path, window: Window) async throws {
        let lock: PrivilegedJobState = path == .manualStart ? .running : .probeFailed(5)
        let h = try Harness(script: .init(runtimeRunning: window == .containerList, running: [], lockStates: [lock]))
        h.startupRecoveryHadItsChance()
        let intent = T.intent(stopIssued: true)
        h.prefs.intent = intent
        var notified = 0
        h.store.onRuntimeLeftStopped = { _, _ in notified += 1 }

        let store = h.store
        let quit: @Sendable (Int) async -> Void = { n in
            guard n == 1 else { return }
            let committed = await store.isInCommittedPhase
            #expect(!committed)                                  // 锁忙路径不算 committed：退出取消我们，而不是等
            await store.prepareForTermination()
        }
        switch window {
        case .runtimeProbe: h.commands.onIsRunning.withLock { $0 = quit }
        case .containerList: h.commands.onList.withLock { $0 = quit }
        }

        switch path {
        case .manualStart: h.store.startRuntime()
        case .recovery: h.store.recoverIfNeeded()
        }
        await h.store.awaitOperationForTests()

        #expect(h.log.count(window == .runtimeProbe ? "is-running" : "ls") == 1)   // 取消确实卡进了那个 await
        #expect(h.store.state == .recovering)
        #expect(notified == 0)
        #expect(h.prefs.intent == intent)
        #expect(h.log.count("start-runtime") == 0)
    }

    // MARK: - R6（codex exec P1）：等锁等满上限、最后一次 sleep 里被取消

    /// 睡眠立即返回，但每次 sleep 之前先跑一个钩子：把取消卡进「某一次 sleep」这个 await。
    struct HookedClock: SupervisorClock {
        let hook: AsyncHook
        func now() -> Date { Date(timeIntervalSince1970: 0) }
        func sleep(until deadline: Date) async {
            await hook.run()
            await Task.yield()
        }
    }

    /// 等锁循环每一轮开头查取消，但最后一轮的 sleep 之后直接出循环——生产时钟被取消时 sleep 立即返回，于是「等满了」和「被取消了」混在一起。
    @Test("osascript 异常结束后等 root 任务等满上限，最后一次 sleep 里退出 → 不进复原：不起运行时、不写状态、不发通知")
    func cancelledDuringLastUnexpectedEndSleepDoesNotRestore() async throws {
        let limit = RuntimeUpdateStore.jobPollLimit
        // 第 1 次探锁 = 装前；第 2…limit+1 次 = 收尾等锁（一直被占着）；再探就是进了 restore——那时锁已空闲，会起运行时。
        let locks: [PrivilegedJobState] = [.idle] + Array(repeating: .running, count: limit) + [.idle]
        let quit = AsyncHook()
        let h = try Harness(
            outcome: .unknown("killed"), script: .init(runtimeRunning: true, running: [], lockStates: locks),
            clock: HookedClock(hook: quit)
        )
        var notified = 0
        h.store.onRuntimeLeftStopped = { _, _ in notified += 1 }
        let store = h.store
        let commands = h.commands
        quit.set { if commands.lockProbeCount.withLock({ $0 }) == limit + 1 { await store.prepareForTermination() } }

        await h.run { $0.checkForUpdates() }

        #expect(h.commands.lockProbeCount.withLock { $0 } == limit + 1)
        #expect(h.log.count("start-runtime") == 0)
        #expect(notified == 0)
        if case .failed = h.store.state { Issue.record("state written after quit: \(h.store.state)") }
        #expect(h.prefs.intent?.owesRuntimeStart == true)          // stop 已发、记录在盘：下次启动恢复
    }

    @Test("恢复流程等锁等满上限，最后一次 sleep 里退出 → 不写失败态（记录留给下次启动）")
    func cancelledDuringLastRecoverySleepWritesNothing() async throws {
        let limit = RuntimeUpdateStore.jobPollLimit
        let quit = AsyncHook()
        let h = try Harness(
            script: .init(runtimeRunning: true, lockStates: Array(repeating: .running, count: limit)),
            clock: HookedClock(hook: quit)
        )
        let intent = T.intent(stopIssued: false)                    // 没有复原义务：出循环后直接写失败态的那条路
        h.prefs.intent = intent
        let store = h.store
        let commands = h.commands
        quit.set { if commands.lockProbeCount.withLock({ $0 }) == limit { await store.prepareForTermination() } }

        await h.run { $0.recoverIfNeeded() }

        #expect(h.commands.lockProbeCount.withLock { $0 } == limit)
        #expect(h.store.state == .recovering)
        #expect(h.prefs.intent == intent)
    }

    // MARK: - D：手动复原按钮的标题跟着义务走（codex 补评 D + D 辩论 3 轮）

    /// 升级失败、起运行时也失败 ⇒ 欠「起运行时」；之后用户在终端起了运行时 ⇒ supervisor 触发 + 新鲜探测解除它，只剩会话内的容器欠账。
    static func dischargedContainerDebt() async throws -> Harness {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        #expect(h.store.manualRestore == .startRuntime)
        h.commands.script.withLock { $0.runtimeRunning = true; $0.start = .succeeded }
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .containersNotRestarted([Self.buildkit])))
        return h
    }

    @Test("欠「起运行时」→ Start Runtime；解除后只欠容器 → Start Remaining Containers，按下只拉容器、不起运行时")
    func titleFollowsObligation() async throws {
        let h = try await Self.dischargedContainerDebt()
        #expect(h.store.manualRestore == .startRemainingContainers)
        let startsBefore = h.log.count("start-runtime")
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == startsBefore)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.store.manualRestore == nil)
    }

    /// codex D 第 1 轮的反例：旧的 `.failed(_, .runtimeStopped)` 只是上一次观测，不是运行时此刻的事实。
    @Test("已解除 + 旧的「运行时停着」失败态 → 仍是 Start Remaining Containers；用户随后起好运行时，按下也只拉容器")
    func staleRuntimeStoppedStateDoesNotPromiseRuntimeStart() async throws {
        let h = try await Self.dischargedContainerDebt()
        // 用户又在终端停了运行时；按按钮时另一个 root 任务持着锁。
        h.commands.script.withLock { $0.runtimeRunning = false; $0.lockStates = [.running] }
        await h.run { $0.startRuntime() }
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .runtimeStopped(because: .anotherJobRunning)))
        #expect(h.store.manualRestore == .startRemainingContainers)
        // 用户在终端起好运行时：已解除的义务不再理会触发，state 还停在「运行时停着」。
        h.commands.script.withLock { $0.runtimeRunning = true; $0.lockStates = [.idle] }
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.store.manualRestore == .startRemainingContainers)
        let startsBefore = h.log.count("start-runtime")
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == startsBefore)
        #expect(h.log.count("start:buildkit") == 1)
    }

    /// 标题是「目标型」：解除之后用户又停了运行时，按下这个按钮会先起运行时再拉容器（R4 E：手动按钮例外）。
    @Test("已解除、运行时又被用户停了 → 标题仍是 Start Remaining Containers，按下先起运行时（前提）再拉容器")
    func remainingContainersTitleStartsRuntimeAsPrerequisite() async throws {
        let h = try await Self.dischargedContainerDebt()
        h.commands.script.withLock { $0.runtimeRunning = false }
        #expect(h.store.manualRestore == .startRemainingContainers)
        let startsBefore = h.log.count("start-runtime")
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == startsBefore + 1)
        #expect(h.log.count("start:buildkit") == 1)
    }

    /// 按钮只跟义务走，不跟 state / pending 走（codex D 第 3 轮的两条负例：防 view 或实现按状态误显）。
    @Test("失败态、甚至带着「尚未重新启动」的欠账文案，但没有义务 → 不显示按钮")
    func noButtonWithoutObligationWhateverTheState() async throws {
        let downloadFailed = try Harness(downloadFailure: .network("offline"))
        downloadFailed.startupRecoveryHadItsChance()
        await downloadFailed.run { $0.checkForUpdates() }
        guard case .failed(_, nil) = downloadFailed.store.state else {
            Issue.record("state: \(downloadFailed.store.state)"); return
        }
        #expect(downloadFailed.store.manualRestore == nil)

        let h = try await Self.dischargedContainerDebt()
        h.store.activeIntent = nil
        h.prefs.intent = nil
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .containersNotRestarted([Self.buildkit])))
        #expect(h.store.manualRestore == nil)
    }

    #if DEBUG
    /// 截图夹具要和真流程同源（codex D 第 3 轮）：按钮与状态行都从同一组语义得出；只写内存，不碰 defaults / 命令。
    @Test("截图夹具：Start Remaining Containers + 「装上了、尚未重新启动」，不写 defaults、不调任何命令")
    func screenshotFixtureUsesRealSemantics() throws {
        let h = try Harness()
        h.startupRecoveryHadItsChance()
        // 盘上预置一份记录：已解除的义务本来就不落盘，经 `recordIntent` 会把它**清成 nil**——只断言 nil 抓不到。
        let onDisk = T.intent(stopIssued: true)
        h.prefs.intent = onDisk
        h.store.presentContainerDebtFixture([Self.buildkit], installed: T.v150, from: T.v141)
        #expect(h.store.manualRestore == .startRemainingContainers)
        #expect(h.store.state == .failed(.installedButNotRestarted(T.v150), pending: .containersNotRestarted([Self.buildkit])))
        #expect(h.store.lastKnownInstalled == T.v150)
        #expect(h.prefs.intent == onDisk)
        #expect(h.log.all.isEmpty)
    }

    /// `.containersNotRestarted` 约定非空（空 = 什么都不欠）；夹具不许造出「有义务、没有容器」这种真流程到不了的状态（codex R6 P2）。
    @Test("截图夹具：空的容器列表 → 什么都不摆")
    func screenshotFixtureRejectsEmptyList() throws {
        let h = try Harness()
        h.startupRecoveryHadItsChance()
        h.store.presentContainerDebtFixture([], installed: T.v150, from: T.v141)
        #expect(h.store.state == .idle)
        #expect(h.store.manualRestore == nil)
    }
    #endif

    @Test("忙 / 副实例 / 没有义务 → 不显示按钮")
    func noButtonWhenBusySecondaryOrNothingOwed() async throws {
        let idle = try Harness()
        idle.startupRecoveryHadItsChance()
        #expect(idle.store.manualRestore == nil)

        let secondary = try Harness(primary: false)
        secondary.startupRecoveryHadItsChance()
        secondary.prefs.intent = T.intent(stopIssued: true)
        #expect(secondary.store.manualRestore == nil)

        let busy = try Harness()
        busy.startupRecoveryHadItsChance()
        busy.prefs.intent = T.intent(stopIssued: true)
        #expect(busy.store.manualRestore == .startRuntime)
        busy.feed.gated.withLock { $0 = true }
        busy.store.automaticCheck()
        #expect(busy.store.isBusy)
        #expect(busy.store.manualRestore == nil)
        busy.feed.release()
        await busy.store.awaitOperationForTests()
    }
}
