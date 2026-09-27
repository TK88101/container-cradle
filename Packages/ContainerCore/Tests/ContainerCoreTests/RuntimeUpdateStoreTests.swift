import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// Day 22 T7：更新器状态机。§5.4 的事件 × 状态表、收尾真值表、AD9 恢复判定，逐格一条。
@MainActor
@Suite("RuntimeUpdateStore：检查 / 升级 / 收尾 / 恢复")
struct RuntimeUpdateStoreTests {

    static let v141 = RuntimeVersion(major: 1, minor: 4, patch: 1)
    static let v150 = RuntimeVersion(major: 1, minor: 5, patch: 0)
    static let release150 = UpdatePolicyTests.release(v150)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    final class Harness {
        let log = EventLog()
        let prefs = InMemoryUpdatePreferences()
        let feed: FakeReleaseFeed
        let downloader: FakeDownloader
        let installer: FakePrivilegedInstaller
        let commands: FakeRuntimeCommands
        let updateLog = SpyRuntimeUpdateLog()
        /// 请 supervisor reconcile 时、记下事件之前执行（R4 G）。
        let reconcileHook = AsyncHook()
        /// 读冻结白名单时、返回之前执行（R4：把取消卡进 handleReady 的读里）。
        let managedHook = AsyncHook()
        let store: RuntimeUpdateStore
        var notified: [RuntimeRelease] = []

        init(
            feed: ReleaseCheckResult = .release(RuntimeUpdateStoreTests.release150),
            callsReady: Bool = true,
            outcome: PrivilegedJobOutcome = .finished(.installed, blockers: [], details: []),
            script: FakeRuntimeCommands.Script = .init(installedAfterInstall: .installed(RuntimeUpdateStoreTests.v150)),
            verification: PackageVerification = .ok,
            downloadFailure: DownloadFailure? = nil,
            managed: Set<String> = [],
            now: (@Sendable () -> Date)? = nil,
            primary: Bool = true,
            reconcileLimit: Duration = .seconds(30),
            clock: any SupervisorClock = ImmediateClock()
        ) throws {
            self.feed = FakeReleaseFeed(log: log, feed)
            self.downloader = try FakeDownloader(log: log, failure: downloadFailure)
            self.commands = FakeRuntimeCommands(log: log, script)
            let commands = self.commands
            self.installer = FakePrivilegedInstaller(
                log: log, callsReady: callsReady, outcome: outcome,
                afterRun: { result in if case .finished(.installed, _, _) = result { commands.markInstalled() } }
            )
            let log = self.log
            let reconcileHook = self.reconcileHook
            let managedHook = self.managedHook
            let managedIDs = Set(managed.compactMap(ContainerID.init))
            let fixedNow = RuntimeUpdateStoreTests.now
            let environment = RuntimeUpdateEnvironment(
                feed: self.feed,
                downloader: downloader,
                verifier: FakeVerifier(log: log, verification),
                installer: installer,
                commands: commands,
                now: now ?? { fixedNow },
                clock: clock,
                log: updateLog,
                managedContainerIDs: { await managedHook.run(); return managedIDs },
                requestManagedReconcile: { await reconcileHook.run(); log.append("reconcile") },
                reconcileRequestLimit: reconcileLimit,
                authorizationPrompt: { from, to in "update \(from) -> \(to)" }
            )
            store = RuntimeUpdateStore(environment: environment, preferences: prefs, isPrimaryInstance: primary)
            store.onUpdateAvailable = { [unowned self] release, _ in self.notified.append(release) }
        }

        func run(_ action: (RuntimeUpdateStore) -> Void) async {
            action(store)
            await store.awaitOperationForTests()
        }

        /// 生产上的稳态：启动恢复已经有过它的机会（`recoverIfNeeded()` 被调用过，R6 5a）——手动复原按钮在那之前不出现。
        /// **显式写在每条测手动按钮的用例里**（装置默认未认领，codex R6：别把这个时间维度压成常数）。
        /// 这些用例随后预置盘上记录、直接按按钮，模拟的是「恢复被 busy 等 guard 挡掉之后仍留在盘上」的记录。
        func startupRecoveryHadItsChance() {
            store.startupRecoveryClaimed = true
        }
    }

    // MARK: - 检查

    @Test("未安装 → notInstalled，不发网络请求")
    func notInstalled() async throws {
        let h = try Harness(script: .init(installed: .notInstalled))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .notInstalled)
        #expect(h.log.count("feed") == 0)
    }

    @Test("读不出已装版本 → checkFailed（不是已是最新）")
    func installedUnknown() async throws {
        let h = try Harness(script: .init(installed: .unknown("boom")))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .checkFailed(.installedVersionUnknown("boom")))
    }

    @Test("自动检查有新版 → available + 通知一次，记下成功时间，不自动升级")
    func automaticAvailable() async throws {
        let h = try Harness()
        await h.run { $0.automaticCheck() }
        #expect(h.store.state == .available(installed: Self.v141, release: Self.release150))
        #expect(h.notified == [Self.release150])
        #expect(h.prefs.lastSuccessfulCheck == Self.now)
        #expect(h.log.count("download") == 0)
    }

    @Test("自动检查：跳过的版本 → skipped，不通知")
    func automaticSkipped() async throws {
        let h = try Harness()
        h.prefs.skippedVersion = Self.v150
        await h.run { $0.automaticCheck() }
        #expect(h.store.state == .skipped(installed: Self.v141, release: Self.release150))
        #expect(h.notified.isEmpty)
    }

    @Test("已是最新")
    func upToDate() async throws {
        let h = try Harness(feed: .release(UpdatePolicyTests.release(Self.v141)))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .upToDate(Self.v141))
    }

    /// A4：查询失败绝不能显示成「已是最新」，也不能被记成一次成功检查。
    @Test("网络失败 → checkFailed，且不记成功时间")
    func networkFailure() async throws {
        let h = try Harness(feed: .failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .checkFailed(.release(.network("offline"))))
        #expect(h.prefs.lastSuccessfulCheck == nil)
    }

    @Test("限流 → 记下解除时间；限流期内手动检查不发请求")
    func rateLimited() async throws {
        let until = Self.now.addingTimeInterval(600)
        let h = try Harness(feed: .rateLimited(until: until))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .checkFailed(.rateLimited(until: until)))
        #expect(h.prefs.rateLimitedUntil == until)

        await h.run { $0.checkForUpdates() }
        #expect(h.log.count("feed") == 1)
    }

    // MARK: - 手动检查直接升级（A3）+ 成功收尾（A6 / AD6）

    @Test("手动检查有新版 → 直接升级；stop 之前意图记录已置 stopIssued；成功后起运行时、恢复未受管容器")
    func manualCheckInstallsDirectly() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(Self.v150), runtimeRunning: true, running: ["buildkit", "open-connector"]
        ), managed: ["open-connector"])
        let prefs = h.prefs
        let sawStopIssued = Mutex<[Bool?]>([])
        h.commands.onStop.withLock { $0 = { @Sendable in
            let issued = await MainActor.run { prefs.intent?.stopIssued }
            sawStopIssued.withLock { $0.append(issued) }
        } }

        await h.run { $0.checkForUpdates() }

        #expect(h.store.state == .succeeded(Self.v150, unrestored: []))
        // 每一次 stop 发生时，意图记录都已经是 stopIssued = true；而且 stop 只有一次。
        #expect(sawStopIssued.withLock { $0 } == [true])
        // 顺序：锁探测 → 下载 → 校验 → 授权 → ready → 快照 → stop → root 结束 → 版本 → 起运行时 → 只起未受管的 buildkit
        let events = h.log.all
        #expect(events.firstIndex(of: "lock")! < events.firstIndex(of: "download")!)
        #expect(events.firstIndex(of: "verify")! < events.firstIndex(of: "authorize")!)
        #expect(events.firstIndex(of: "ready")! < events.firstIndex(of: "stop")!)
        #expect(events.firstIndex(of: "stop")! < events.firstIndex(of: "root-finished")!)
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.log.count("start:open-connector") == 0)   // 归 supervisor
        #expect(h.prefs.intent == nil)
        #expect(!FileManager.default.fileExists(atPath: h.downloader.directory.path))   // 临时目录清掉
        #expect(h.installer.prompts.withLock { $0 } == ["update 1.4.1 -> 1.5.0"])
    }

    // MARK: - M2：要装的版本交给 root 核对 PackageInfo

    @Test("交给 root 的目标版本 = 这次 release 的版本")
    func passesTargetVersionToRoot() async throws {
        let h = try Harness()
        await h.run { $0.checkForUpdates() }
        #expect(h.installer.versions.withLock { $0 } == [Self.v150])
    }

    // MARK: - L10：root 级动作的日志时间线

    @Test("成功升级的日志：started → ready(stopIssued) → finished(installed) → restored，同一个 nonce")
    func logsSuccessfulJob() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(Self.v150), runtimeRunning: true, running: ["buildkit", "open-connector"]
        ), managed: ["open-connector"])
        await h.run { $0.checkForUpdates() }

        guard case .started(let nonce, _, _, _) = h.updateLog.events.first else {
            Issue.record("no started event: \(h.updateLog.events)"); return
        }
        #expect(h.updateLog.events == [
            .started(nonce: nonce, target: Self.v150, from: Self.v141, digest: Self.release150.packageSHA256),
            .ready(nonce: nonce, runtimeWasRunning: true, stopIssued: true, runningContainers: 2),
            .finished(nonce: nonce, outcome: .finished(.installed, blockers: [], details: [])),
            .restored(nonce: nonce, leftStopped: false, hold: .none, startOutcome: .succeeded, unrestoredContainers: 0),
        ])
    }

    @Test("取消的日志：started → finished(cancelled)，没有 ready / restored")
    func logsCancelledJob() async throws {
        let h = try Harness(callsReady: false, outcome: .cancelled)
        await h.run { $0.checkForUpdates() }
        guard case .started(let nonce, _, _, _) = h.updateLog.events.first else {
            Issue.record("no started event: \(h.updateLog.events)"); return
        }
        #expect(h.updateLog.events.dropFirst() == [.finished(nonce: nonce, outcome: .cancelled)])
    }

    @Test("复原失败的日志：restored(leftStopped: true) 带着 start 的结局")
    func logsRuntimeLeftStopped() async throws {
        let failure = CommandOutcome.failed(exitCode: 1, detail: "x")
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: [], start: failure)
        )
        await h.run { $0.checkForUpdates() }
        guard case .restored(_, let leftStopped, .startFailed, let start, _) = h.updateLog.events.last else {
            Issue.record("last event is not restored: \(h.updateLog.events)"); return
        }
        #expect(leftStopped)
        #expect(start == failure)
    }

    // MARK: - A5：取消 = 运行时从未被停

    @Test("密码框取消 → cancelled，stop 零次，意图记录清掉")
    func cancelNeverStops() async throws {
        let h = try Harness(callsReady: false, outcome: .cancelled)
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .cancelled)
        #expect(h.log.count("stop") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent == nil)
    }

    @Test("user 侧校验失败 → failed，不弹授权、不碰运行时")
    func userSideVerificationFailure() async throws {
        let h = try Harness(verification: .digestMismatch)
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.verification(.digestMismatch), pending: nil))
        #expect(h.log.count("authorize") == 0)
        #expect(h.log.count("stop") == 0)
    }

    @Test("另一个 root 任务在跑 → failed，连下载都不做")
    func anotherJobRunning() async throws {
        let h = try Harness(script: .init(lockStates: [.running]))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.anotherJobRunning, pending: nil))
        #expect(h.log.count("download") == 0)
    }

    @Test("root 侧复验失败（ready 之前）→ failed，不复原（从未停）")
    func rootVerificationFailure() async throws {
        let h = try Harness(callsReady: false, outcome: .finished(.signerUntrusted, blockers: [], details: []))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.rootVerification(.signerUntrusted), pending: nil))
        #expect(h.log.count("start-runtime") == 0)
    }

    // MARK: - 收尾真值表

    @Test("stop-timeout → 复原运行时与容器，报阻塞者")
    func stopTimeoutRestores() async throws {
        let h = try Harness(
            outcome: .finished(.stopTimeout, blockers: ["/usr/local/bin/container"], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.stopTimedOut(blockers: ["/usr/local/bin/container"]), pending: nil))
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
    }

    @Test("install-failed 且复原失败 → 运行时停着（原因：起不来），意图记录保留（留给「启动运行时」与下次启动）")
    func installFailedAndStartFails() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: ["installer-exit=1"]),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.installFailed(details: ["installer-exit=1"]), pending: .runtimeStopped(because: .startFailed(.failed(exitCode: 1, detail: "x")))))
        #expect(h.prefs.intent?.stopIssued == true)
    }

    /// codex R1 [P1] 的第二层：是否复原只看客观的 stopIssued，不看结果类别——
    /// 就算某个「本该在 ready 之前」的结果在 stop 之后出现，也要把运行时起回来。
    @Test("stop 之后才出现的复验类失败 → 仍按 stopIssued 复原")
    func verificationFailureAfterStopStillRestores() async throws {
        let h = try Harness(
            outcome: .finished(.digestMismatch, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.rootVerification(.digestMismatch), pending: nil))
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
    }

    /// 安全评审 L5：取消码只可能出现在授权**之前**；若 stop 已经发出（ready 之后），那不是一次「取消」，
    /// 而是脚本没按契约结束——按 unknown 走：等锁空闲、复原运行时，绝不静默地把运行时丢在停止状态。
    @Test("ready 之后才出现的 (-128) → 按 unknown 复原，不报「已取消」")
    func cancelAfterStopRestores() async throws {
        let h = try Harness(outcome: .cancelled, script: .init(runtimeRunning: true, running: ["buildkit"]))
        await h.run { $0.checkForUpdates() }
        guard case .failed(.unknown, pending: nil) = h.store.state else {
            Issue.record("expected failed(.unknown), got \(h.store.state)"); return
        }
        #expect(h.log.count("stop") == 1)
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
    }

    // MARK: - L8：defaults 是多实例共享的，本次操作以内存里的意图记录为准

    @Test("授权期间另一实例清掉了 defaults 里的意图记录 → ready 时照样写回（stopIssued 在 stop 之前），失败后照样复原")
    func intentClearedByOtherInstanceBeforeReady() async throws {
        let h = try Harness(
            outcome: .finished(.stopTimeout, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        let prefs = h.prefs
        h.installer.beforeReady.withLock { $0 = { @Sendable in await MainActor.run { prefs.intent = nil } } }
        let sawStopIssued = Mutex<[Bool?]>([])
        h.commands.onStop.withLock { $0 = { @Sendable in
            let issued = await MainActor.run { prefs.intent?.stopIssued }
            sawStopIssued.withLock { $0.append(issued) }
        } }

        await h.run { $0.checkForUpdates() }

        #expect(sawStopIssued.withLock { $0 } == [true])
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.store.state == .failed(.stopTimedOut(blockers: []), pending: nil))
    }

    @Test("stop 之后另一实例清掉了 defaults 里的意图记录 → 收尾照样按本次记录复原")
    func intentClearedByOtherInstanceAfterStop() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"])
        )
        let prefs = h.prefs
        h.commands.onStop.withLock { $0 = { @Sendable in await MainActor.run { prefs.intent = nil } } }

        await h.run { $0.checkForUpdates() }

        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.store.state == .failed(.installFailed(details: []), pending: nil))
    }

    /// codex R1 [P2]：「启动运行时」执行期间要算 busy，连点不会并发起两次。
    @Test("启动运行时执行期间 isBusy，重复点击被忽略")
    func manualStartIsSingleFlight() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: [], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        h.commands.script.withLock { $0.start = .succeeded; $0.lockStates = [.idle] }
        h.store.startRuntime()
        #expect(h.store.isBusy)
        h.store.startRuntime()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("start-runtime") == 2)   // 上一次失败的 1 次 + 这次的 1 次
    }

    @Test("启动运行时失败 → 回到原失败态（按钮还在）")
    func manualStartFailureRestoresFailedState() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: [], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        let failed = h.store.state
        await h.run { $0.startRuntime() }
        #expect(h.store.state == failed)
    }

    // raced 的两种客观状态（运行时停着 / 被别人起来了）见 RuntimeUpdateStoreR2Tests。旧的「raced → 不代为启动」
    // 守的是错误行为：它的 fake 在 stop 之后运行时是停着的，却断言不复原（R2 P0）。

    @Test("unknown（osascript 异常）且已发 stop → 锁空闲后复原")
    func unknownRestoresAfterLockIdle() async throws {
        let h = try Harness(outcome: .unknown("killed"), script: .init(runtimeRunning: true, running: [], lockStates: [.idle, .running, .idle]))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.unknown("killed"), pending: nil))
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("lock") >= 3)
    }

    @Test("升级前运行时本来就停着 → 装完不代为启动，也不起容器")
    func runtimeWasStopped() async throws {
        let h = try Harness(script: .init(installedAfterInstall: .installed(Self.v150), runtimeRunning: false, running: []))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .succeeded(Self.v150, unrestored: []))
        #expect(h.log.count("stop") == 0)
        #expect(h.log.count("start-runtime") == 0)
    }

    @Test("装完版本不对 → versionMismatch")
    func versionMismatch() async throws {
        let h = try Harness(script: .init(installedAfterInstall: .installed(Self.v141)))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.versionMismatch(installed: .installed(Self.v141)), pending: nil))
    }

    @Test("容器恢复：失败但最终在跑算恢复；真起不来的列入 unrestored")
    func containerRestoreReporting() async throws {
        let h = try Harness(script: .init(
            installedAfterInstall: .installed(Self.v150), runtimeRunning: true, running: ["a1", "b2", "c3"],
            containerStart: ["a1": .failed(exitCode: 1, detail: "already"), "b2": .failed(exitCode: 1, detail: "boom")],
            runningAfterFailedStart: ["a1"]
        ))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .succeeded(Self.v150, unrestored: [ContainerID("b2")!]))
    }

    // MARK: - 单飞与合并

    @Test("升级进行中再点 install / 检查 → 忽略")
    func singleFlight() async throws {
        let h = try Harness()
        await h.run { $0.automaticCheck() }
        h.store.install()
        h.store.install()
        h.store.checkForUpdates()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("authorize") == 1)
    }

    @Test("自动检查进行中点手动检查 → 合并：结果可用则直接升级")
    func manualMergesIntoAutomatic() async throws {
        let h = try Harness()
        h.feed.gated.withLock { $0 = true }
        h.store.automaticCheck()
        while h.log.count("feed") == 0 { await Task.yield() }
        h.store.checkForUpdates()
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.log.count("feed") == 1)
        #expect(h.log.count("authorize") == 1)
        #expect(h.notified.isEmpty)
    }

    // MARK: - skip / later / updateNow

    @Test("skip：记下版本、转 skipped；later：回到 idle")
    func skipAndLater() async throws {
        let h = try Harness()
        await h.run { $0.automaticCheck() }
        h.store.skip()
        #expect(h.prefs.skippedVersion == Self.v150)
        #expect(h.store.state == .skipped(installed: Self.v141, release: Self.release150))

        let h2 = try Harness()
        await h2.run { $0.automaticCheck() }
        h2.store.later()
        #expect(h2.store.state == .idle)
        #expect(h2.prefs.skippedVersion == nil)
    }

    /// 通知的「跳过此版本」动作带着版本号——App 可能已重启、store 不在 available 态。
    @Test("按版本跳过：store 不在 available 也照记")
    func skipByVersion() async throws {
        let h = try Harness()
        h.store.skip(version: Self.v150)
        #expect(h.prefs.skippedVersion == Self.v150)
    }

    @Test("updateNow：available 时直接装；否则走手动检查")
    func updateNow() async throws {
        let h = try Harness()
        await h.run { $0.updateNow() }
        #expect(h.log.count("feed") == 1)
        #expect(h.log.count("authorize") == 1)
    }

    // MARK: - 启动运行时（failed + 运行时停着）

    @Test("启动运行时：锁忙 → 不动；锁空闲 → 起运行时并按意图记录恢复容器")
    func startRuntimeAfterFailure() async throws {
        let h = try Harness(
            outcome: .finished(.installFailed, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], start: .failed(exitCode: 1, detail: "x"))
        )
        h.startupRecoveryHadItsChance()
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .failed(.installFailed(details: []), pending: .runtimeStopped(because: .startFailed(.failed(exitCode: 1, detail: "x")))))

        h.commands.script.withLock { $0.start = .succeeded; $0.lockStates = [.running] }
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == 1)   // 锁忙：只有上一次失败的那一次

        h.commands.script.withLock { $0.lockStates = [.idle] }
        await h.run { $0.startRuntime() }
        #expect(h.log.count("start-runtime") == 2)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.prefs.intent == nil)
        #expect(h.store.state == .idle)
    }

    // MARK: - 崩溃恢复（AD9）

    static func intent(stopIssued: Bool, wasRunning: Bool = true) -> UpdateIntent {
        UpdateIntent(
            nonce: UUID(), target: v150, from: v141, runtimeWasRunning: wasRunning, stopIssued: stopIssued,
            runningContainerIDs: [ContainerID("buildkit")!, ContainerID("open-connector")!],
            managedContainerIDs: [ContainerID("open-connector")!]
        )
    }

    @Test("没有意图记录 → 什么都不做")
    func recoveryWithoutIntent() async throws {
        let h = try Harness()
        await h.run { $0.recoverIfNeeded() }
        #expect(h.store.state == .idle)
        #expect(h.log.all.isEmpty)
    }

    @Test("有记录、锁忙 → 等到空闲；装成功 → 起运行时、恢复未受管、请 supervisor reconcile、清记录")
    func recoveryAfterCrash() async throws {
        let h = try Harness(script: .init(
            installed: .installed(Self.v150), runtimeRunning: false, running: [], lockStates: [.running, .running, .idle]
        ))
        let intent = Self.intent(stopIssued: true)
        h.prefs.intent = intent
        h.installer.stateFile.withLock { $0 = .done(.installed) }
        await h.run { $0.recoverIfNeeded() }
        #expect(h.store.state == .succeeded(Self.v150, unrestored: []))
        #expect(h.log.count("start-runtime") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.log.count("start:open-connector") == 0)
        #expect(h.log.count("reconcile") == 1)
        #expect(h.prefs.intent == nil)
        #expect(h.updateLog.events.first == .recovering(nonce: intent.nonce, stopIssued: true, stateFile: .done(.installed)))
    }

    @Test("有记录但从未发 stop → 无事可做，清记录")
    func recoveryWithoutStop() async throws {
        let h = try Harness(script: .init(runtimeRunning: true))
        h.prefs.intent = Self.intent(stopIssued: false)
        await h.run { $0.recoverIfNeeded() }
        #expect(h.store.state == .idle)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.prefs.intent == nil)
    }

    @Test("锁探测失败 → 保留记录，报失败")
    func recoveryProbeFailed() async throws {
        let h = try Harness(script: .init(runtimeRunning: false, lockStates: [.probeFailed(73)]))
        h.prefs.intent = Self.intent(stopIssued: true)
        await h.run { $0.recoverIfNeeded() }
        #expect(h.store.state == .failed(.lockProbeFailed(73), pending: .runtimeStopped(because: .lockProbeFailed(73))))
        #expect(h.prefs.intent != nil)
    }

    // MARK: - 退出

    @Test("空闲时退出：立刻放行")
    func terminationWhenIdle() async throws {
        let h = try Harness()
        #expect(h.store.isInCommittedPhase == false)
        await h.store.prepareForTermination()
    }
}
