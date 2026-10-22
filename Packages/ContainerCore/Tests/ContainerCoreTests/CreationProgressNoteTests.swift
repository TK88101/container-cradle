import Foundation
import Testing

@testable import ContainerCore

/// Day 25（Plan 2026-10-22 §2.4 / T6）：提交 ≥ 30 s 提示「仍在进行」；确认中提示「等待结果」。
@Suite("ContainerCreationPresentation.progressNote")
struct CreationProgressNoteTests {

    static let start = Date(timeIntervalSince1970: 1_000_000)
    static let en = Locale(identifier: "en")
    static let stillWorking = "Still working. The first container after a runtime update can take a few minutes."
    static let waiting = "The runtime has not answered yet. Waiting for the result…"

    private func note(confirming: Bool = false, submittedAt: Date? = start, after seconds: TimeInterval) -> String? {
        ContainerCreationPresentation.progressNote(
            isConfirming: confirming,
            submittedAt: submittedAt,
            now: Self.start.addingTimeInterval(seconds),
            locale: Self.en
        )
    }

    @Test("不到 30 s 不提示")
    func silentBeforeThreshold() {
        #expect(note(after: 0) == nil)
        #expect(note(after: 29.9) == nil)
    }

    @Test("满 30 s 起提示「仍在进行」")
    func stillWorkingFromThreshold() {
        #expect(note(after: 30) == Self.stillWorking)
        #expect(note(after: 200) == Self.stillWorking)
    }

    @Test("确认中：不论过了多久都提示「等待结果」")
    func confirmingAlwaysNotes() {
        #expect(note(confirming: true, after: 0) == Self.waiting)
        #expect(note(confirming: true, after: 400) == Self.waiting)
    }

    @Test("submittedAt 为 nil（不在提交中）⇒ 一律 nil，含确认中 + nil 的组合")
    func nilWhenNotSubmitting() {
        #expect(note(submittedAt: nil, after: 100) == nil)
        #expect(note(confirming: true, submittedAt: nil, after: 100) == nil)
    }

    @Test("四语有译文", arguments: ["ja", "zh-Hans", "zh-Hant"])
    func translated(language: String) {
        let locale = Locale(identifier: language)
        let still = ContainerCreationPresentation.progressNote(
            isConfirming: false, submittedAt: Self.start, now: Self.start.addingTimeInterval(31), locale: locale
        )
        let waiting = ContainerCreationPresentation.progressNote(
            isConfirming: true, submittedAt: Self.start, now: Self.start, locale: locale
        )
        #expect(still != nil && still != Self.stillWorking, "\(language)")
        #expect(waiting != nil && waiting != Self.waiting, "\(language)")
    }
}
