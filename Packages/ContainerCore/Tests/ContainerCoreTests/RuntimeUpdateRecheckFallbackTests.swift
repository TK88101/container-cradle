import Foundation
import Testing

@testable import ContainerCore

/// Day 24 A（Plan 2026-10-21 §2.1）：检查失败不丢手上已持有的 release。
/// 现场：`.available` 态再点「检查更新」撞 403 限流 → `.checkFailed` 覆盖了 `.available`，「Update Now」消失。
@MainActor
@Suite("RuntimeUpdateStore：检查失败回退到已持有的 release")
struct RuntimeUpdateRecheckFallbackTests {

    typealias Harness = RuntimeUpdateStoreTests.Harness
    static let v141 = RuntimeUpdateStoreTests.v141
    static let v150 = RuntimeUpdateStoreTests.v150
    static let release150 = RuntimeUpdateStoreTests.release150
    static let until = RuntimeUpdateStoreTests.now.addingTimeInterval(600)

    /// 自动检查得到 `.available(1.4.1, 1.5.0)`，然后把 feed 换成 `next`。
    func availableThen(_ next: ReleaseCheckResult) async throws -> Harness {
        let h = try Harness()
        await h.run { $0.automaticCheck() }
        #expect(h.store.state == .available(installed: Self.v141, release: Self.release150))
        h.feed.result.withLock { $0 = next }
        return h
    }

    // MARK: - 三个失败出口都回退

    @Test("available + feed 限流 → 仍 available，recheckFailure = rateLimited，照旧记下解除时间")
    func feedRateLimited() async throws {
        let h = try await availableThen(.rateLimited(until: Self.until))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .available(installed: Self.v141, release: Self.release150))
        #expect(h.store.recheckFailure == .rateLimited(until: Self.until))
        #expect(h.prefs.rateLimitedUntil == Self.until)
    }

    @Test("available + feed 失败 → 仍 available，recheckFailure = release(...)")
    func feedFailed() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .available(installed: Self.v141, release: Self.release150))
        #expect(h.store.recheckFailure == .release(.network("offline")))
    }

    @Test("available + 前置限流闸未到期 → 仍 available，不发请求")
    func preflightRateLimitGate() async throws {
        let h = try await availableThen(.release(Self.release150))
        h.prefs.rateLimitedUntil = Self.until
        let feedCalls = h.log.count("feed")
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .available(installed: Self.v141, release: Self.release150))
        #expect(h.store.recheckFailure == .rateLimited(until: Self.until))
        #expect(h.log.count("feed") == feedCalls)
    }

    @Test("skipped + feed 失败 → 回到 skipped（跳过的版本本来就没有安装按钮）")
    func skippedFallsBackToSkipped() async throws {
        let h = try Harness()
        h.prefs.skippedVersion = Self.v150
        await h.run { $0.automaticCheck() }
        #expect(h.store.state == .skipped(installed: Self.v141, release: Self.release150))
        h.feed.result.withLock { $0 = .failed(.network("offline")) }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .skipped(installed: Self.v141, release: Self.release150))
        #expect(h.store.recheckFailure == .release(.network("offline")))
    }

    // MARK: - 不回退的情形

    @Test("已装版本已 ≥ held → 不回退，照原行为 checkFailed")
    func installedCaughtUp() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        h.commands.script.withLock { $0.installed = .installed(Self.v150) }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .checkFailed(.release(.network("offline"))))
        #expect(h.store.recheckFailure == nil)
    }

    @Test("回退用这次新读的已装版本（D-A1）")
    func usesFreshInstalledVersion() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        let v142 = RuntimeVersion(major: 1, minor: 4, patch: 2)
        h.commands.script.withLock { $0.installed = .installed(v142) }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .available(installed: v142, release: Self.release150))
    }

    @Test("读不出已装版本 → 不回退")
    func installedUnknownDoesNotFallBack() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        h.commands.script.withLock { $0.installed = .unknown("boom") }
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .checkFailed(.installedVersionUnknown("boom")))
        #expect(h.store.recheckFailure == nil)
    }

    @Test("没有 held（idle 起手）→ 原行为 checkFailed")
    func noHeldRelease() async throws {
        let h = try Harness(feed: .failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        #expect(h.store.state == .checkFailed(.release(.network("offline"))))
        #expect(h.store.recheckFailure == nil)
    }

    // MARK: - 副作用

    @Test("回退不发通知（不是新发现），也不自动开装（D-A2）")
    func fallbackDoesNotNotifyOrInstall() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        #expect(h.notified == [Self.release150])
        #expect(h.log.count("download") == 0)
    }

    @Test("回退后 install() 照常可用")
    func installAfterFallback() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        await h.run { $0.install() }
        #expect(h.log.count("download") == 1)
        #expect(h.store.recheckFailure == nil)
    }

    // MARK: - recheckFailure 生命周期（每个离开出口）

    @Test("later() → idle，recheckFailure 清零")
    func laterClears() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        h.store.later()
        #expect(h.store.state == .idle)
        #expect(h.store.recheckFailure == nil)
    }

    @Test("再次检查进 checking → recheckFailure 清零")
    func recheckClearsWhileChecking() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        h.feed.gated.withLock { $0 = true }
        h.store.checkForUpdates()
        #expect(h.store.state == .checking)
        #expect(h.store.recheckFailure == nil)
        h.feed.release()
        await h.store.awaitOperationForTests()
    }

    @Test("成功检查重写 available → recheckFailure 清零")
    func successfulCheckClears() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        h.feed.result.withLock { $0 = .release(Self.release150) }
        await h.run { $0.automaticCheck() }
        #expect(h.store.state == .available(installed: Self.v141, release: Self.release150))
        #expect(h.store.recheckFailure == nil)
    }

    /// 夹具 ≡ 真路径（前置限流闸那条出口），而不是 ≡ 一组写死的期望值：
    /// `failCheck` 将来一改，写死的版本照绿、验收截图却悄悄和真实行为对不上（Plan 2026-10-23 §2.4）。
    /// 结果本身对不对由上面那些用例（行为 oracle）守。
    @Test("DEBUG 夹具摆出的就是真实回退路径写出的那组状态（A/B-fx）")
    func fixtureMatchesFallback() async throws {
        let real = try await availableThen(.release(Self.release150))
        real.prefs.rateLimitedUntil = Self.until
        await real.run { $0.checkForUpdates() }
        #expect(real.store.recheckFailure != nil, "真路径应已回退；否则比较的是两份空状态")

        let h = try Harness()
        h.store.presentRecheckFailureFixture(installed: Self.v141, release: Self.release150, failure: .rateLimited(until: Self.until))
        #expect(h.store.state == real.store.state)
        #expect(h.store.recheckFailure == real.store.recheckFailure)
        #expect(h.store.lastKnownInstalled == Self.v141)
    }

    @Test("skip()（available → skipped，同一 release）→ recheckFailure 保留")
    func skipKeeps() async throws {
        let h = try await availableThen(.failed(.network("offline")))
        await h.run { $0.checkForUpdates() }
        h.store.skip()
        #expect(h.store.state == .skipped(installed: Self.v141, release: Self.release150))
        #expect(h.store.recheckFailure == .release(.network("offline")))
    }
}
