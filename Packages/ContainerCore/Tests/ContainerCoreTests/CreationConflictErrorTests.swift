import Foundation
import Testing

@testable import ContainerCore

/// Day 25（Plan 2026-10-22 §2.2）：本 App 自己挡下的两种「这次没有发出」——同名在途、在途数到上限。
/// 都不是失败，也不暗示运行时坏了；文案不加 "Create failed:" 前缀。
@Suite("creationInProgress / creationLimitReached：文案（分类见 FailureClassificationTests）")
struct CreationConflictErrorTests {

    static let inProgress = RuntimeError.creation(.inProgress(name: "web"))
    static let limitReached = RuntimeError.creation(.limitReached(limit: 8))
    static let en = Locale(identifier: "en")

    static let inProgressText =
        "A container named web is already being created in this app. The name stays reserved until that request returns or you reopen the app. Check the container list in the menu before trying again."
    static let limitText =
        "8 container creations are still in progress. Wait for them to finish, then try again. If this persists, reopen the app."

    @Test("create 提交被挡：专用文案，不说 failed")
    func createMessages() {
        let inProgress = ContainerCreationPresentation.message(
            for: ContainerCreationStore.Failure.createFailed(Self.inProgress), locale: Self.en
        )
        let limit = ContainerCreationPresentation.message(
            for: ContainerCreationStore.Failure.createFailed(Self.limitReached), locale: Self.en
        )
        #expect(inProgress == Self.inProgressText)
        #expect(limit == Self.limitText)
        #expect(!inProgress.localizedCaseInsensitiveContains("failed"))
        #expect(!limit.localizedCaseInsensitiveContains("failed"))
    }

    @Test("clone 提交被挡：同一句")
    func cloneMessages() {
        #expect(
            ContainerCreationPresentation.message(
                for: ContainerCloneStore.SubmitFailure.createFailed(Self.inProgress), locale: Self.en
            ) == Self.inProgressText
        )
        #expect(
            ContainerCreationPresentation.message(
                for: ContainerCloneStore.SubmitFailure.createFailed(Self.limitReached), locale: Self.en
            ) == Self.limitText
        )
    }

    @Test("四语有译文", arguments: ["ja", "zh-Hans", "zh-Hant"])
    func translated(language: String) {
        let locale = Locale(identifier: language)
        let inProgress = ContainerCreationPresentation.message(
            for: ContainerCreationStore.Failure.createFailed(Self.inProgress), locale: locale
        )
        let limit = ContainerCreationPresentation.message(
            for: ContainerCreationStore.Failure.createFailed(Self.limitReached), locale: locale
        )
        #expect(!inProgress.isEmpty && inProgress != Self.inProgressText, "\(language)")
        #expect(inProgress.contains("web"), "\(language)：名字要带出来")
        #expect(!limit.isEmpty && limit != Self.limitText, "\(language)")
        #expect(limit.contains("8"), "\(language)：上限要带出来")
    }

    @Test("CreationOperationID：每次生成都不同（不可由名字换出）")
    func operationIDsAreUnique() {
        let ids = (0..<100).map { _ in CreationOperationID() }
        #expect(Set(ids).count == 100)
    }
}
