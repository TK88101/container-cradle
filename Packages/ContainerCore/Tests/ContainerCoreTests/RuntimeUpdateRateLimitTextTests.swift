import Foundation
import Testing

@testable import ContainerCore

/// Day 24 B（Plan 2026-10-21 §2.2）：限流提示过了解除时刻就改口；回退时的「没能重新确认」一行（§2.1 文案）。
/// 现场：10:24 解除的限流，11:49 菜单仍写「10:24 以后再试」——读起来像持续失败。
@Suite("RuntimeUpdatePresentation：限流提示到期改口、recheckNote、needsPeriodicRefresh")
struct RuntimeUpdateRateLimitTextTests {

    static let now = RuntimeUpdatePresentationTests.now
    static let en = RuntimeUpdatePresentationTests.en
    static let foreign = RuntimeUpdatePresentationTests.foreign
    static let release = RuntimeUpdatePresentationTests.release
    static let v141 = RuntimeUpdatePresentationTests.v141
    static let reset = "GitHub rate limit has reset. Check for updates again."

    static func rateLimitedText(until: Date, now: Date, locale: Locale = en) -> String? {
        RuntimeUpdatePresentation.statusText(for: .checkFailed(.rateLimited(until: until)), now: now, locale: locale)
    }

    // MARK: - 到期改口

    @Test("now < until：原文案（带解除时刻）")
    func beforeReset() {
        let text = Self.rateLimitedText(until: Self.now.addingTimeInterval(1), now: Self.now)
        #expect(text?.hasPrefix("GitHub rate limit reached. Try again after ") == true)
    }

    @Test("now == until：已解除，改口（边界算解除）")
    func atReset() {
        #expect(Self.rateLimitedText(until: Self.now, now: Self.now) == Self.reset)
    }

    @Test("now > until：改口，不再出现过去的时刻")
    func afterReset() {
        #expect(Self.rateLimitedText(until: Self.now.addingTimeInterval(-3600), now: Self.now) == Self.reset)
    }

    @Test("改口文案四语都有译文", arguments: foreign)
    func resetTranslated(locale: Locale) {
        let translated = Self.rateLimitedText(until: Self.now, now: Self.now, locale: locale)
        #expect(translated != nil && translated != Self.reset, "\(locale.identifier)")
    }

    // MARK: - recheckNote

    @Test("recheckNote：前缀 + checkFailureText（网络失败）")
    func recheckNoteNetwork() {
        #expect(RuntimeUpdatePresentation.recheckNote(.release(.network("offline")), now: Self.now, locale: Self.en)
            == "Couldn't re-check just now: Update check failed: offline")
    }

    @Test("recheckNote：限流到期同样改口")
    func recheckNoteRateLimitReset() {
        #expect(RuntimeUpdatePresentation.recheckNote(.rateLimited(until: Self.now), now: Self.now, locale: Self.en)
            == "Couldn't re-check just now: \(Self.reset)")
    }

    @Test("recheckNote 四语都有译文", arguments: foreign)
    func recheckNoteTranslated(locale: Locale) {
        let failure = CheckFailure.release(.http(500))
        let english = RuntimeUpdatePresentation.recheckNote(failure, now: Self.now, locale: Self.en)
        let translated = RuntimeUpdatePresentation.recheckNote(failure, now: Self.now, locale: locale)
        #expect(!translated.isEmpty && translated != english, "\(locale.identifier)")
    }

    // MARK: - needsPeriodicRefresh（view 挂不挂每秒刷新的 TimelineView）

    @Test("checkFailed(rateLimited) → 要刷新")
    func refreshForRateLimitedState() {
        #expect(RuntimeUpdatePresentation.needsPeriodicRefresh(for: .checkFailed(.rateLimited(until: Self.now)), recheckFailure: nil))
    }

    @Test("available + recheckFailure 限流 → 要刷新")
    func refreshForRecheckFailure() {
        let state = RuntimeUpdateStore.State.available(installed: Self.v141, release: Self.release)
        #expect(RuntimeUpdatePresentation.needsPeriodicRefresh(for: state, recheckFailure: .rateLimited(until: Self.now)))
    }

    @Test("其它状态 / 非限流失败 → 不刷新")
    func noRefreshOtherwise() {
        let available = RuntimeUpdateStore.State.available(installed: Self.v141, release: Self.release)
        #expect(!RuntimeUpdatePresentation.needsPeriodicRefresh(for: .idle, recheckFailure: nil))
        #expect(!RuntimeUpdatePresentation.needsPeriodicRefresh(for: available, recheckFailure: nil))
        #expect(!RuntimeUpdatePresentation.needsPeriodicRefresh(for: available, recheckFailure: .release(.network("x"))))
        #expect(!RuntimeUpdatePresentation.needsPeriodicRefresh(for: .checkFailed(.release(.http(500))), recheckFailure: nil))
    }
}
