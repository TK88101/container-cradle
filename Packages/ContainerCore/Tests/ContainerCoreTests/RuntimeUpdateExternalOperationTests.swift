import Foundation
import Testing

@testable import ContainerCore

/// Day 23 T2：更新器对「外部运行时操作」（运行时自动启动）的租约。
/// 持有期间更新器所有会动运行时的入口都按既有单飞规则挡住；租约只认匹配的 token，释放幂等（Plan 2026-09-29 §2.3）。
@MainActor
@Suite("RuntimeUpdateStore：外部运行时操作租约")
struct RuntimeUpdateExternalOperationTests {

    typealias H = RuntimeUpdateStoreTests.Harness

    static func pendingIntent() -> UpdateIntent {
        UpdateIntent(
            nonce: UUID(), target: RuntimeUpdateStoreTests.v150, from: RuntimeUpdateStoreTests.v141,
            runtimeWasRunning: true, stopIssued: true
        )
    }

    @Test("空闲时拿得到租约；持有期间 isBusy，释放后恢复")
    func acquireAndRelease() throws {
        let h = try H()
        let token = try #require(h.store.tryBeginExternalRuntimeOperation())
        #expect(h.store.isBusy)
        h.store.endExternalRuntimeOperation(token)
        #expect(!h.store.isBusy)
    }

    @Test("已被持有 → 第二次拿不到")
    func singleHolder() throws {
        let h = try H()
        _ = try #require(h.store.tryBeginExternalRuntimeOperation())
        #expect(h.store.tryBeginExternalRuntimeOperation() == nil)
    }

    @Test("更新器自己在忙 → 拿不到")
    func refusedWhileUpdaterBusy() async throws {
        let h = try H()
        h.feed.gated.withLock { $0 = true }
        h.store.automaticCheck()
        #expect(h.store.isBusy)
        #expect(h.store.tryBeginExternalRuntimeOperation() == nil)
        h.feed.release()
        await h.store.awaitOperationForTests()
    }

    @Test("有待补的启动恢复 → 拿不到（补做优先）")
    func refusedWhileRecoveryDeferred() throws {
        let h = try H()
        h.store.deferredRecoveryNonce = UUID()
        #expect(!h.store.isBusy)
        #expect(h.store.tryBeginExternalRuntimeOperation() == nil)
    }

    @Test("有待补的重启确认 → 拿不到")
    func refusedWhileRestartCheckPending() throws {
        let h = try H()
        h.store.restartCheckPending = true
        #expect(h.store.tryBeginExternalRuntimeOperation() == nil)
    }

    @Test("退出开始之后 → 拿不到")
    func refusedWhileTerminating() throws {
        let h = try H()
        h.store.beginTermination()
        #expect(h.store.tryBeginExternalRuntimeOperation() == nil)
    }

    /// codex R1 #1：只有真欠「起运行时」义务的记录才让 starter 让路；遗留 / 已解除的不挡。
    @Test("pendingIntentOwesRuntimeStart：只认真欠起运行时的意图记录")
    func owesRuntimeStartOnlyForRealObligation() throws {
        let h = try H()
        #expect(!h.store.pendingIntentOwesRuntimeStart)

        h.prefs.intent = Self.pendingIntent()
        #expect(h.store.pendingIntentOwesRuntimeStart)

        var notStopped = Self.pendingIntent()
        notStopped.stopIssued = false
        h.prefs.intent = notStopped
        #expect(!h.store.pendingIntentOwesRuntimeStart)

        var wasNotRunning = Self.pendingIntent()
        wasNotRunning.runtimeWasRunning = false
        h.prefs.intent = wasNotRunning
        #expect(!h.store.pendingIntentOwesRuntimeStart)

        var discharged = Self.pendingIntent()
        discharged.startDischarged = true
        h.prefs.intent = discharged
        #expect(!h.store.pendingIntentOwesRuntimeStart)
    }

    @Test("非主实例 → 拿不到")
    func refusedOnSecondaryInstance() throws {
        let h = try H(primary: false)
        #expect(h.store.tryBeginExternalRuntimeOperation() == nil)
    }

    @Test("持有期间：检查、手动检查、安装、恢复都不开新操作")
    func blocksUpdaterEntries() async throws {
        let h = try H()
        await h.run { $0.automaticCheck() }   // 先拿到 available，install() 才有东西装
        #expect(h.log.count("feed") == 1)
        let token = try #require(h.store.tryBeginExternalRuntimeOperation())

        h.store.automaticCheck()
        h.store.checkForUpdates()
        h.store.install()
        h.prefs.intent = Self.pendingIntent()
        h.store.recoverIfNeeded()
        await h.store.awaitOperationForTests()

        #expect(h.log.count("feed") == 1)
        #expect(h.log.count("download") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(!h.store.isAutomaticCheckDue())
        h.store.endExternalRuntimeOperation(token)
    }

    @Test("持有期间「启动运行时」按钮不可用")
    func manualStartUnavailable() throws {
        let h = try H()
        h.prefs.intent = Self.pendingIntent()
        h.store.startupRecoveryClaimed = true
        #expect(h.store.canStartRuntime)
        let token = try #require(h.store.tryBeginExternalRuntimeOperation())
        #expect(!h.store.canStartRuntime)
        h.store.endExternalRuntimeOperation(token)
    }

    @Test("错 token / 重复释放是 no-op")
    func releaseIsIdempotent() throws {
        let h = try H()
        let first = try #require(h.store.tryBeginExternalRuntimeOperation())
        h.store.endExternalRuntimeOperation(first)
        let second = try #require(h.store.tryBeginExternalRuntimeOperation())
        h.store.endExternalRuntimeOperation(first)   // 过期 token
        #expect(h.store.isBusy)
        h.store.endExternalRuntimeOperation(second)
        h.store.endExternalRuntimeOperation(second)  // 重复
        #expect(!h.store.isBusy)
    }

    @Test("释放后补做持有期间被挡掉的启动恢复")
    func releaseRunsDeferredRecovery() async throws {
        let h = try H(script: .init(runtimeRunning: false, running: []))
        let token = try #require(h.store.tryBeginExternalRuntimeOperation())
        h.prefs.intent = Self.pendingIntent()
        h.store.recoverIfNeeded()
        #expect(h.log.count("start-runtime") == 0)

        h.store.endExternalRuntimeOperation(token)
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 1)
    }

    @Test("退出途中释放照样生效（不留永久 busy），但不补做恢复")
    func releaseWhileTerminating() async throws {
        let h = try H(script: .init(runtimeRunning: false, running: []))
        let token = try #require(h.store.tryBeginExternalRuntimeOperation())
        h.prefs.intent = Self.pendingIntent()
        h.store.recoverIfNeeded()
        h.store.beginTermination()

        h.store.endExternalRuntimeOperation(token)
        await h.store.awaitOperationForTests()
        #expect(!h.store.isBusy)
        #expect(h.log.count("start-runtime") == 0)
    }
}
