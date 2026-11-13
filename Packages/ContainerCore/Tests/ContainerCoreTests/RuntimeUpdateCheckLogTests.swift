import Foundation
import Testing

@testable import ContainerCore

/// Plan 2026-11-13 C4：每次**真正发起**的更新检查记一对日志——开始（trigger）与结局（allowlist）。
/// 事后要能还原「几点查过、查出了什么」；没真正发起的（非主实例、合并进在途检查）一条都不记（codex R1-C4a）。
/// 每个实际启动的检查**严格一对** `[started, finished]`：漏记 / 重记都是本组测试要照红的（codex R1-C4d）。
@MainActor
@Suite("RuntimeUpdateStore：检查日志成对、结局准确")
struct RuntimeUpdateCheckLogTests {

    typealias T = RuntimeUpdateStoreTests
    typealias Harness = RuntimeUpdateStoreTests.Harness
    typealias Check = SpyRuntimeUpdateLog.CheckEvent

    @Test("未安装 → notInstalled")
    func notInstalled() async throws {
        let h = try Harness(script: .init(installed: .notInstalled))
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.notInstalled)])
    }

    @Test("读不出已装版本 → installedUnknown（不带 reason 文本）")
    func installedUnknown() async throws {
        let h = try Harness(script: .init(installed: .unknown("boom")))
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.installedUnknown)])
    }

    @Test("自动检查有新版 → available(版本)")
    func automaticAvailable() async throws {
        let h = try Harness()
        await h.run { $0.automaticCheck() }
        #expect(h.updateLog.checkEvents == [.started(.automatic), .finished(.available(T.v150))])
    }

    @Test("跳过的版本 → skipped(版本)")
    func skipped() async throws {
        let h = try Harness()
        h.prefs.skippedVersion = T.v150
        await h.run { $0.automaticCheck() }
        #expect(h.updateLog.checkEvents == [.started(.automatic), .finished(.skipped(T.v150))])
    }

    @Test("已是最新 → upToDate(已装版本)")
    func upToDate() async throws {
        let h = try Harness(feed: .release(UpdatePolicyTests.release(T.v141)))
        await h.run { $0.automaticCheck() }
        #expect(h.updateLog.checkEvents == [.started(.automatic), .finished(.upToDate(T.v141))])
    }

    @Test("GitHub 限流 → rateLimited")
    func rateLimitedByFeed() async throws {
        let h = try Harness(feed: .rateLimited(until: T.now.addingTimeInterval(600)))
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.rateLimited)])
    }

    @Test("本地记着的限流还没到期 → rateLimitedLocally，不发请求")
    func rateLimitedLocally() async throws {
        let h = try Harness()
        h.prefs.rateLimitedUntil = T.now.addingTimeInterval(600)
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.rateLimitedLocally)])
        #expect(h.log.count("feed") == 0)
    }

    @Test(
        "请求失败 → failed(kind)：只记类别，不记错误文字 / HTTP 码",
        arguments: [
            (ReleaseCheckFailure.network("offline: secret-ish detail"), CheckFailureKind.network),
            (ReleaseCheckFailure.http(503), CheckFailureKind.http),
            (ReleaseCheckFailure.feed(.malformed), CheckFailureKind.feed),
        ]
    )
    func failed(failure: ReleaseCheckFailure, kind: CheckFailureKind) async throws {
        let h = try Harness(feed: .failed(failure))
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.failed(kind))])
    }

    /// codex R1-C4b：手动检查发现新版会在**同一个** `runCheck` 里进安装。结局必须在安装开始**之前**记，
    /// 而不是等安装跑完才补一条「检查完成」（时间线失真，安装失败会被读成检查失败）。
    @Test("手动检查有新版 → available 先于安装的 job started 记下")
    func manualAvailableIsLoggedBeforeInstall() async throws {
        let h = try Harness()
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.available(T.v150))])
        let finishedIndex = try #require(h.updateLog.allEvents.firstIndex(of: .check(.finished(.available(T.v150)))))
        let jobIndex = try #require(h.updateLog.allEvents.firstIndex { if case .started = $0 { true } else { false } })
        #expect(finishedIndex < jobIndex)
    }

    @Test("读已装版本时退出 → [started, cancelled]")
    func quitDuringVersionRead() async throws {
        let h = try Harness()
        let store = h.store
        h.commands.onVersion.withLock { $0 = { @Sendable in await store.prepareForTermination() } }
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.cancelled)])
    }

    @Test("GitHub 请求进行中退出 → [started, cancelled]")
    func quitDuringFeed() async throws {
        let h = try Harness()
        h.feed.gated.withLock { $0 = true }
        h.store.checkForUpdates()
        while h.log.count("feed") == 0 { await Task.yield() }
        await h.store.prepareForTermination()
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.updateLog.checkEvents == [.started(.manual), .finished(.cancelled)])
    }

    @Test("自动检查进行中点手动检查 → 合并，只有一对")
    func mergedCheckLogsOnePair() async throws {
        let h = try Harness(feed: .release(UpdatePolicyTests.release(T.v141)))
        h.feed.gated.withLock { $0 = true }
        h.store.automaticCheck()
        while h.log.count("feed") == 0 { await Task.yield() }
        h.store.checkForUpdates()
        h.feed.release()
        await h.store.awaitOperationForTests()
        #expect(h.updateLog.checkEvents == [.started(.automatic), .finished(.upToDate(T.v141))])
    }

    @Test("非主实例 → 不检查、不记")
    func secondaryInstanceLogsNothing() async throws {
        let h = try Harness(primary: false)
        await h.run { $0.checkForUpdates() }
        #expect(h.updateLog.checkEvents.isEmpty)
    }

    @Test("连查两次 → 两对，各自成对")
    func twoChecksLogTwoPairs() async throws {
        let h = try Harness(feed: .release(UpdatePolicyTests.release(T.v141)))
        await h.run { $0.automaticCheck() }
        await h.run { $0.automaticCheck() }
        let pair: [Check] = [.started(.automatic), .finished(.upToDate(T.v141))]
        #expect(h.updateLog.checkEvents == pair + pair)
    }
}
