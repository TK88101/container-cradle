import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T2：要不要提醒 / 要不要升级，以及自动检查什么时候到期。纯函数真值表。
@Suite("UpdatePolicy：决策真值表与检查到期")
struct UpdatePolicyTests {

    static let v141 = RuntimeVersion(major: 1, minor: 4, patch: 1)
    static let v150 = RuntimeVersion(major: 1, minor: 5, patch: 0)
    static let v160 = RuntimeVersion(major: 1, minor: 6, patch: 0)

    static func release(_ version: RuntimeVersion) -> RuntimeRelease {
        RuntimeRelease(
            version: version,
            packageName: "container-\(version)-installer-signed.pkg",
            packageURL: URL(string: "https://github.com/apple/container/releases/download/\(version)/x.pkg")!,
            packageSHA256: SHA256Digest(hex: String(repeating: "a", count: 64))!,
            packageSize: 1,
            releasePageURL: URL(string: "https://github.com/apple/container/releases/tag/\(version)")!
        )
    }

    // MARK: - decide

    @Test("最新版不比已装的新 → 已是最新（两种触发都一样）", arguments: [UpdateTrigger.automatic, .manual])
    func upToDate(trigger: UpdateTrigger) {
        #expect(UpdatePolicy.decide(installed: Self.v141, latest: Self.release(Self.v141), skipped: nil, trigger: trigger)
            == .upToDate(installed: Self.v141))
        // 本机比 GitHub latest 还新（自己编的、或 latest 回退了）也算「已是最新」，不提示「降级」。
        #expect(UpdatePolicy.decide(installed: Self.v150, latest: Self.release(Self.v141), skipped: nil, trigger: trigger)
            == .upToDate(installed: Self.v150))
    }

    @Test("有新版且没跳过 → 可用（两种触发都一样）", arguments: [UpdateTrigger.automatic, .manual])
    func available(trigger: UpdateTrigger) {
        let latest = Self.release(Self.v150)
        #expect(UpdatePolicy.decide(installed: Self.v141, latest: latest, skipped: nil, trigger: trigger)
            == .available(installed: Self.v141, release: latest))
    }

    @Test("自动检查：跳过的正是这个版本 → skipped（不提醒）")
    func automaticRespectsSkip() {
        let latest = Self.release(Self.v150)
        #expect(UpdatePolicy.decide(installed: Self.v141, latest: latest, skipped: Self.v150, trigger: .automatic)
            == .skipped(installed: Self.v141, release: latest))
    }

    /// 用户点「检查更新」是明确意图，跳过只管自动提醒（A2）。
    @Test("手动检查：跳过对它无效 → 可用")
    func manualIgnoresSkip() {
        let latest = Self.release(Self.v150)
        #expect(UpdatePolicy.decide(installed: Self.v141, latest: latest, skipped: Self.v150, trigger: .manual)
            == .available(installed: Self.v141, release: latest))
    }

    /// 跳过的是 1.5.0，出了 1.6.0 → 照常提醒（A2 的后半句）。
    @Test("跳过的是旧版本，出了更新的 → 照常可用")
    func skipDoesNotCoverNewerVersion() {
        let latest = Self.release(Self.v160)
        #expect(UpdatePolicy.decide(installed: Self.v141, latest: latest, skipped: Self.v150, trigger: .automatic)
            == .available(installed: Self.v141, release: latest))
    }

    // MARK: - isCheckDue

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let day: TimeInterval = 24 * 60 * 60

    @Test("从没成功检查过 → 到期")
    func dueWhenNeverChecked() {
        #expect(UpdatePolicy.isCheckDue(now: Self.now, lastSuccess: nil, rateLimitedUntil: nil, isEnabled: true))
    }

    @Test("距上次成功不足 24h → 未到期；恰好 24h 及以上 → 到期")
    func dueAfterInterval() {
        #expect(!UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: Self.now.addingTimeInterval(-Self.day + 1), rateLimitedUntil: nil, isEnabled: true))
        #expect(UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: Self.now.addingTimeInterval(-Self.day), rateLimitedUntil: nil, isEnabled: true))
        #expect(UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: Self.now.addingTimeInterval(-3 * Self.day), rateLimitedUntil: nil, isEnabled: true))
    }

    /// 记录的「上次成功」在未来 = 时钟被往回调过。那份记录不可信——当作到期，否则要等时钟追上才会再检查。
    @Test("时钟倒退（上次成功在未来）→ 到期")
    func dueWhenClockWentBackwards() {
        #expect(UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: Self.now.addingTimeInterval(3600), rateLimitedUntil: nil, isEnabled: true))
    }

    @Test("限流期内 → 未到期；限流已解除 → 照常判断")
    func respectsRateLimit() {
        #expect(!UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: nil, rateLimitedUntil: Self.now.addingTimeInterval(60), isEnabled: true))
        #expect(UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: nil, rateLimitedUntil: Self.now, isEnabled: true))
    }

    /// A12：开关关掉，自动检查一次都不发。
    @Test("开关关闭 → 永不到期")
    func disabledNeverDue() {
        #expect(!UpdatePolicy.isCheckDue(now: Self.now, lastSuccess: nil, rateLimitedUntil: nil, isEnabled: false))
        #expect(!UpdatePolicy.isCheckDue(
            now: Self.now, lastSuccess: Self.now.addingTimeInterval(-10 * Self.day), rateLimitedUntil: nil, isEnabled: false))
    }
}
