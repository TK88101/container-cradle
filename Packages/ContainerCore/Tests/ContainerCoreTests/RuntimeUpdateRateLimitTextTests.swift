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

    // MARK: - needsPeriodicRefresh / refreshDeadline（view 挂不挂每秒刷新的 TimelineView；Day 26 到点摘掉）

    static let available = RuntimeUpdateStore.State.available(installed: v141, release: release)

    private static func needs(_ state: RuntimeUpdateStore.State, _ recheck: CheckFailure?, at offset: TimeInterval) -> Bool {
        RuntimeUpdatePresentation.needsPeriodicRefresh(for: state, recheckFailure: recheck, now: now.addingTimeInterval(offset))
    }

    @Test("checkFailed(rateLimited)：until 之前、until 到 until+1s 之间要刷新；≥ until+1s 不刷新")
    func refreshForRateLimitedState() {
        let state = RuntimeUpdateStore.State.checkFailed(.rateLimited(until: Self.now))
        #expect(Self.needs(state, nil, at: -30))
        #expect(Self.needs(state, nil, at: 0.5))
        #expect(!Self.needs(state, nil, at: 1))
        #expect(!Self.needs(state, nil, at: 60))
    }

    @Test("available + recheckFailure 限流：同一组边界")
    func refreshForRecheckFailure() {
        let recheck = CheckFailure.rateLimited(until: Self.now)
        #expect(Self.needs(Self.available, recheck, at: -30))
        #expect(Self.needs(Self.available, recheck, at: 0.5))
        #expect(!Self.needs(Self.available, recheck, at: 1))
    }

    @Test("其它状态 / 非限流失败 → 不刷新，deadline 为 nil")
    func noRefreshOtherwise() {
        let cases: [(RuntimeUpdateStore.State, CheckFailure?)] = [
            (.idle, nil),
            (Self.available, nil),
            (Self.available, .release(.network("x"))),
            (.checkFailed(.release(.http(500))), nil),
        ]
        for (state, recheck) in cases {
            #expect(!Self.needs(state, recheck, at: -30))
            #expect(RuntimeUpdatePresentation.refreshDeadline(for: state, recheckFailure: recheck) == nil)
        }
    }

    @Test("refreshDeadline = until + 1 s；两处都带 until 时取最晚（防提早停刷新）")
    func deadlineTakesLatest() {
        let early = Self.now
        let late = Self.now.addingTimeInterval(120)
        #expect(
            RuntimeUpdatePresentation.refreshDeadline(for: .checkFailed(.rateLimited(until: early)), recheckFailure: nil)
                == early.addingTimeInterval(1)
        )
        #expect(
            RuntimeUpdatePresentation.refreshDeadline(
                for: .checkFailed(.rateLimited(until: early)), recheckFailure: .rateLimited(until: late)
            ) == late.addingTimeInterval(1)
        )
        #expect(
            RuntimeUpdatePresentation.refreshDeadline(
                for: .checkFailed(.rateLimited(until: late)), recheckFailure: .rateLimited(until: early)
            ) == late.addingTimeInterval(1)
        )
        #expect(Self.needs(.checkFailed(.rateLimited(until: early)), .rateLimited(until: late), at: 60))
    }
}
