import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 评审 R4 辩论收敛的设计改动：义务拆成「起运行时 / 拉容器」（E、E-6'）、committed 段里没有无界的 await（第 3 轮 (a)(b)）。
@MainActor
@Suite("RuntimeUpdateStore R4：起运行时与拉容器两份义务、committed 段有界")
struct RuntimeUpdateStoreR4ObligationTests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    static let buildkit = ContainerID("buildkit")!
    static let openConnector = ContainerID("open-connector")!

    // MARK: - E-6'：supervisor 看到运行时在跑 = 触发；新鲜探测 = 证据

    /// 升级把运行时留在停止态（起不来）。
    private func leftStoppedHarness() async throws -> Harness {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        #expect(h.prefs.intent?.owesRuntimeStart == true, "setup: \(h.store.state)")
        return h
    }

    @Test("留在停止态后用户手动起了运行时 → 新鲜探测为真：「起运行时」义务解除、defaults 清、菜单不再说运行时停着")
    func observedRestartDischargesStartObligation() async throws {
        let h = try await leftStoppedHarness()
        h.commands.script.withLock { $0.runtimeRunning = true }   // 用户 `container system start`
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.prefs.intent == nil)
        #expect(h.store.canStartRuntime)                           // 本次会话里仍可一键拉回容器
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .containersNotRestarted([Self.buildkit])))
    }

    @Test("解除之后用户又把运行时停了、再升级（ready 时运行时停着）→ 装完不去起它（R-U12）")
    func dischargedObligationIsNotRevivedByReinstall() async throws {
        let h = try await leftStoppedHarness()
        h.commands.script.withLock { $0.runtimeRunning = true }
        await h.run { $0.runtimeMayHaveRestarted() }

        h.commands.script.withLock {                                // 用户 `container system stop`
            $0.runtimeRunning = false
            $0.start = .succeeded
            $0.installedAfterInstall = .installed(T.v150)
        }
        h.installer.queuedOutcomes.withLock { $0 = [.finished(.installed, blockers: [], details: [])] }
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("start-runtime") == 1)                 // 只有第一次升级那次失败的
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.prefs.intent == nil)
        #expect(!h.store.canStartRuntime)
    }

    @Test("解除之后运行时被用户停着、再升级时复原遇锁忙 → 不报「运行时停着」、不发通知（那不是我们停的）")
    func dischargedObligationWithLockHeldIsNotReportedAsStopped() async throws {
        let h = try await leftStoppedHarness()
        h.commands.script.withLock { $0.runtimeRunning = true }
        await h.run { $0.runtimeMayHaveRestarted() }

        h.commands.script.withLock {
            $0.runtimeRunning = false
            $0.installedAfterInstall = .installed(T.v150)
            $0.lockStates = [.idle, .running]
        }
        h.installer.queuedOutcomes.withLock { $0 = [.finished(.installed, blockers: [], details: [])] }
        var notified = 0
        h.store.onRuntimeLeftStopped = { _, _ in notified += 1 }
        await h.run { $0.checkForUpdates() }
        #expect(notified == 0)
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
        #expect(h.prefs.intent == nil)
    }

    @Test("旧快照晚到（运行时其实停着）→ 新鲜探测为假：义务原样落盘、状态不变")
    func staleTriggerIsIgnored() async throws {
        let h = try await leftStoppedHarness()
        let before = h.store.state
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.prefs.intent?.owesRuntimeStart == true)
        #expect(h.store.state == before)
    }

    @Test("探测途中开始了新操作 → 回来后放弃（op 对不上），义务不动")
    func triggerAbandonedWhenOperationStarts() async throws {
        let h = try await leftStoppedHarness()
        h.feed.result.withLock { $0 = .failed(.network("offline")) }
        h.commands.script.withLock { $0.runtimeRunning = true }
        let store = h.store
        h.commands.onIsRunning.withLock { $0 = { @Sendable _ in await store.checkForUpdates() } }
        await h.run { $0.runtimeMayHaveRestarted() }
        #expect(h.prefs.intent?.owesRuntimeStart == true)
    }

    // MARK: - 第 3 轮 (a)：handleReady 先读、后进 committed

    enum ReadPoint: String, CaseIterable, Sendable {
        case isRunning, list, managed
    }

    @Test("ready 之后的三次读里任一次时退出 → 此刻不算 committed、退出放行；不 stop、不写 stopIssued", arguments: ReadPoint.allCases)
    func quitDuringReadyReadsDoesNotStop(point: ReadPoint) async throws {
        let h = try Harness(script: .init(installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"]))
        let store = h.store
        let committedAtRead = Mutex<Bool?>(nil)
        let quit: @Sendable () async -> Void = {
            let committed = await store.isInCommittedPhase
            committedAtRead.withLock { $0 = $0 ?? committed }
            // committed 时退出会等这个任务本身（= 死锁）：只记录，让断言去红。
            if !committed { await store.prepareForTermination() }
        }
        switch point {
        case .isRunning: h.commands.onIsRunning.withLock { $0 = { @Sendable n in if n == 1 { await quit() } } }
        case .list: h.commands.onList.withLock { $0 = { @Sendable n in if n == 1 { await quit() } } }
        case .managed: h.managedHook.set(quit)
        }
        await h.run { $0.checkForUpdates() }
        #expect(committedAtRead.withLock { $0 } == false)
        #expect(h.log.count("stop") == 0)
        #expect(h.prefs.intent?.stopIssued != true)
    }

    // MARK: - 第 3 轮 (b)：reconcile 请求有上限

    @Test("恢复流程请 reconcile 挂死 → 在上限内结束；受管容器列为欠账（只在本次会话），defaults 清，「启动运行时」可用")
    func reconcileRequestIsBounded() async throws {
        let h = try Harness(
            script: .init(installed: .installed(T.v150), runtimeRunning: false, running: []),
            reconcileLimit: .milliseconds(50)
        )
        h.startupRecoveryHadItsChance()
        h.prefs.intent = T.intent(stopIssued: true)
        h.installer.stateFile.withLock { $0 = .done(.installed) }
        // 永不返回、也不响应取消（Task.sleep 会响应取消，拿它当挂死会让没有上限的实现变绿）。
        h.reconcileHook.set { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
        await h.run { $0.recoverIfNeeded() }
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.store.state == .failed(.installedButNotRestarted(T.v150), pending: .containersNotRestarted([Self.openConnector])))
        #expect(h.prefs.intent == nil)
        #expect(h.store.canStartRuntime)
        #expect(!h.store.isInCommittedPhase)
        guard case .restored(_, false, .reconcileRequestTimedOut, _, 1) = h.updateLog.events.last else {
            Issue.record("last log event: \(String(describing: h.updateLog.events.last))"); return
        }
    }

    // MARK: - C：root 任务可能还没结束（osascript 异常）

    @Test("unknown 结局且锁一直被占着 → 不起运行时；如实说明原因是「另一个更新在进行」，义务留着")
    func unknownWithJobStillRunningReportsWhy() async throws {
        let h = try Harness(outcome: .unknown("killed"), script: .init(runtimeRunning: true, running: [], lockStates: [.idle, .running]))
        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.store.state == .failed(.unknown("killed"), pending: .runtimeStopped(because: .anotherJobRunning)))
        #expect(h.prefs.intent?.owesRuntimeStart == true)
    }

    // MARK: - 义务记录

    @Test("旧记录（没有 startDischarged 键）照样读得出来，按「起运行时义务还在」算")
    func legacyIntentDecodes() throws {
        let intent = T.intent(stopIssued: true)
        let encoded = try JSONEncoder().encode(intent)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.removeValue(forKey: "startDischarged") != nil)
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(UpdateIntent.self, from: legacy)
        #expect(decoded == intent)
        #expect(decoded.owesRuntimeStart)
    }

    @Test("被锁挡住的复原：日志 hold = lock-held，leftStopped 反映运行时真的停着")
    func blockedRestoreLogsHold() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"], lockStates: [.idle, .running]
        ))
        await h.run { $0.checkForUpdates() }
        guard case .restored(_, let leftStopped, let hold, nil, 0) = h.updateLog.events.last else {
            Issue.record("last log event: \(String(describing: h.updateLog.events.last))"); return
        }
        #expect(leftStopped)
        #expect(hold == .lockHeld)
        #expect(h.store.state == .failed(.installedButNotRestarted(T.v150), pending: .runtimeStopped(because: .anotherJobRunning)))
    }
}
