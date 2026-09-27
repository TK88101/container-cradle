import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// Day 22 附录 C：T13 遗留四项里的两处修复。
///
/// - **C3**：退出交接期间白名单勾选仍可点。写入链在交接里只被等一次，之后的勾选没人等、退出即丢——
///   界面勾着、磁盘没有，下次开机 supervisor 不拉。冻结必须**同步**发生在退出入口（`applicationShouldTerminate`
///   里 `Task {}` 之前），写在 `prepareForQuit` 第一句不够：那里已经隔着一次调度（codex 附录 C 第 1 轮 P1）。
/// - **C4**（R-U9）：停机前 `ls` 失败时原实现把快照当成空列表照样 stop ⇒ 未受管容器被停、不会被拉回、没有提示。
///   改为 fail-closed：不 stop、不写 stopIssued；root 等不到停机 → stop-timeout，什么都不装（与 T13 ⑤ 同一条路径）。
@MainActor
@Suite("T13 遗留：退出时同步冻结白名单 / 更新器；停机前 ls 失败 ⇒ 不停机")
struct T13LeftoverTests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    // MARK: - C3：白名单冻结

    @Test("冻结之后勾选 / 取消 / 移除都不改内存、不落盘；冻结之前排队的写照常落盘")
    func frozenWhitelistIgnoresMutations() async {
        let writer = FakeWhitelistWriter(entries: [WhitelistEntry(id: id("keep"), enabled: true)])
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), true)          // 冻结之前：照常
        store.freeze()
        store.setManaged(id("b"), true)
        store.setManaged(id("keep"), false)
        store.remove(id("keep"))
        await store.awaitWrites()

        #expect(store.isFrozen)
        #expect(store.isManaged(id("a")))
        #expect(!store.isManaged(id("b")))
        #expect(store.isManaged(id("keep")))
        let saved = await writer.saved
        #expect(saved.count == 1)
        #expect(saved.last?.contains(WhitelistEntry(id: id("a"), enabled: true)) == true)
        #expect(saved.last?.contains(WhitelistEntry(id: id("keep"), enabled: true)) == true)
    }

    static func lifecycle(_ r: AppLifecycleTests.Recorder) -> AppLifecycle {
        AppLifecycle(steps: .init(
            beginStartup: { r.append("startup") },
            startSupervisor: { r.append("sv-start") },
            loadWhitelist: { r.append("load") },
            beginBackgroundWork: { r.append("background") },
            beginQuit: { r.append("quit") },
            prepareForQuit: { r.append("prepare") },
            stopSupervisor: { r.append("sv-stop") }
        ))
    }

    @Test("beginQuit 同步做完、只做一次；随后的 stop 不重复它，且它排在 prepare 之前")
    func beginQuitIsSynchronousAndOnce() async {
        let r = AppLifecycleTests.Recorder()
        let lifecycle = Self.lifecycle(r)
        await lifecycle.start()

        lifecycle.beginQuit()
        #expect(r.events.last == "quit")         // 调用返回时已经做完（同步），没有隔着调度

        lifecycle.beginQuit()
        await lifecycle.stop()
        #expect(r.count("quit") == 1)
        #expect(r.events.suffix(3) == ["quit", "prepare", "sv-stop"])
    }

    @Test("没调 beginQuit 直接 stop → stop 先做 beginQuit 再 prepare")
    func stopBeginsQuitFirst() async {
        let r = AppLifecycleTests.Recorder()
        let lifecycle = Self.lifecycle(r)
        await lifecycle.start()
        await lifecycle.stop()
        #expect(r.events.suffix(3) == ["quit", "prepare", "sv-stop"])
    }

    @Test("更新器的 beginTermination 同步置位：之后检查 / 立即更新 / 跳过版本都不接")
    func beginTerminationIsSynchronous() async throws {
        let h = try Harness()
        h.startupRecoveryHadItsChance()

        h.store.beginTermination()
        #expect(h.store.isTerminating)

        h.store.checkForUpdates()
        h.store.updateNow()
        h.store.skip(version: T.v150)
        #expect(h.store.task == nil)
        #expect(h.prefs.skippedVersion == nil)
        #expect(h.log.all.isEmpty)
    }

    // MARK: - C4：停机前 ls 失败 ⇒ fail-closed

    @Test("运行时在跑、停机前 ls 失败 ⇒ 不停机、不写 stopIssued；等 root 放弃时显示 abandoning；root 超时 ⇒ snapshotUnavailable，运行时与容器都不被动")
    func listFailureDoesNotStop() async throws {
        let h = try Harness(
            outcome: .finished(.stopTimeout, blockers: ["/usr/local/bin/container"], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], listFails: true)
        )
        let store = h.store
        let seen = Mutex<RuntimeUpdateStore.State?>(nil)
        let intentAtReady = Mutex<UpdateIntent?>(nil)
        let prefs = h.prefs
        h.installer.afterReady.withLock {
            $0 = {
                let (state, intent) = await MainActor.run { (store.state, prefs.intent) }
                seen.withLock { $0 = state }
                intentAtReady.withLock { $0 = intent }
            }
        }

        await h.run { $0.checkForUpdates() }

        #expect(h.log.count("stop") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("start:buildkit") == 0)
        #expect(seen.withLock { $0 } == .updating(T.release150, .abandoning))
        #expect(intentAtReady.withLock { $0 }?.stopIssued == false)
        #expect(h.store.state == .failed(.snapshotUnavailable, pending: nil))
        #expect(h.prefs.intent == nil)
        #expect(h.updateLog.events.contains { if case .snapshotUnavailable = $0 { true } else { false } })
    }

    @Test("等 root 放弃的那段里退出 ⇒ prepareForTermination 不等 root；被取消之后什么都不写（不 stop、不起运行时、不写终态），盘上记录 stopIssued=false 留给下次启动清掉")
    func quitWhileAbandoningIsNotHeld() async throws {
        let h = try Harness(
            outcome: .finished(.stopTimeout, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], listFails: true)
        )
        // root 在 ready 之后一直不结束，直到我们放行（迭代 AsyncStream 响应取消，不会冻住）。
        let (rootEnds, release) = AsyncStream<Void>.makeStream()
        h.installer.afterReady.withLock { $0 = { for await _ in rootEnds { break } } }

        h.store.checkForUpdates()
        var spins = 0
        while h.store.state != .updating(T.release150, .abandoning), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(h.store.state == .updating(T.release150, .abandoning))
        #expect(!h.store.isInCommittedPhase)

        // 不等 root：root 还卡在 afterReady 里。有界地等退出返回，然后无论如何放行 root——
        // 若 abandoning 被当成 committed，退出会等 root，这里要**变红**而不是冻住（CLAUDE.md：冻住 ≠ 变红）。
        let store = h.store
        let quitReturned = Mutex(false)
        let quit = Task { @MainActor in
            await store.prepareForTermination()
            quitReturned.withLock { $0 = true }
        }
        spins = 0
        while !quitReturned.withLock({ $0 }), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(quitReturned.withLock { $0 }, "退出被 root 挡住了：abandoning 不应算 committed")
        release.finish()
        await quit.value
        await h.store.awaitOperationForTests()

        #expect(h.log.count("stop") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.store.state == .updating(T.release150, .abandoning))   // 被取消 ⇒ 不写终态
        #expect(h.prefs.intent?.stopIssued == false)
        #expect(!UpdateStage.abandoning.isCommitted)
    }

    @Test("ls 失败后立刻放弃、不再读白名单（那次读要排空写入链，可能卡住）")
    func listFailureDoesNotReadWhitelist() async throws {
        let h = try Harness(
            outcome: .finished(.stopTimeout, blockers: [], details: []),
            script: .init(runtimeRunning: true, running: ["buildkit"], listFails: true)
        )
        let managedRead = Mutex(false)
        h.managedHook.set { managedRead.withLock { $0 = true } }
        await h.run { $0.checkForUpdates() }
        #expect(!managedRead.withLock { $0 })
        #expect(h.store.state == .failed(.snapshotUnavailable, pending: nil))
    }

    @Test("ls 失败、而用户在 root 等待期间自己停了运行时 ⇒ root 装了：不替用户起运行时、不拉容器（我们没停任何东西）")
    func listFailureThenInstalledByOthersStopDoesNotRestore() async throws {
        let h = try Harness(
            outcome: .finished(.installed, blockers: [], details: []),
            script: .init(installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"], listFails: true)
        )
        await h.run { $0.checkForUpdates() }

        #expect(h.log.count("stop") == 0)
        #expect(h.log.count("start-runtime") == 0)
        #expect(h.log.count("start:buildkit") == 0)
        #expect(h.prefs.intent == nil)
    }

    @Test("正控制：ls 成功 ⇒ 照常停机、照常拉回快照里的容器")
    func listSuccessStillStops() async throws {
        let h = try Harness(script: .init(installedAfterInstall: .installed(T.v150), runtimeRunning: true, running: ["buildkit"]))
        await h.run { $0.checkForUpdates() }

        #expect(h.log.count("stop") == 1)
        #expect(h.log.count("start:buildkit") == 1)
        #expect(h.store.state == .succeeded(T.v150, unrestored: []))
    }
}
