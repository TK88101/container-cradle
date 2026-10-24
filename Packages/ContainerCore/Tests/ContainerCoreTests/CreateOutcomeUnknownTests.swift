import Foundation
import Testing

@testable import ContainerCore

/// Day 24：create / clone 超时 = 结果未知（可能仍会完成）。界面不能说「失败」，要说「先去列表里确认再重试」。
@Suite("outcomeUnknown：文案（分类见 FailureClassificationTests）")
struct CreateOutcomeUnknownTests {

    static let error = RuntimeError.creation(.outcomeUnknown(reason: "XPC call timed out (300 seconds)"))
    static let en = Locale(identifier: "en")
    static let expected = "This is taking longer than expected and may still finish. Check the container list in the menu before trying again."

    @Test("create 提交失败：不说 failed，指向列表确认")
    func createMessage() {
        let text = ContainerCreationPresentation.message(for: ContainerCreationStore.Failure.createFailed(Self.error), locale: Self.en)
        #expect(text == Self.expected)
        #expect(!text.contains("timed out"))
    }

    @Test("clone 提交失败：同一句")
    func cloneMessage() {
        let text = ContainerCreationPresentation.message(for: ContainerCloneStore.SubmitFailure.createFailed(Self.error), locale: Self.en)
        #expect(text == Self.expected)
    }

    @Test("四语有译文", arguments: ["ja", "zh-Hans", "zh-Hant"])
    func translated(language: String) {
        let text = ContainerCreationPresentation.message(
            for: ContainerCreationStore.Failure.createFailed(Self.error), locale: Locale(identifier: language)
        )
        #expect(!text.isEmpty && text != Self.expected, "\(language)")
    }
}
