import Foundation
import Testing

@testable import ContainerCore

/// Day 28（Plan 2026-11-10-pin-1.7.1 §2.1 b′）：运行中的 apiserver < 1.6.1 且镜像不在本地时，
/// 本 App **不发** create（旧 server 不认识 1.7.1 client 的 `.imagePlatforms` 路由、不回复，会挂到 300s 超时）。
/// 与 `.inProgress` / `.limitReached` 同类：本 App 挡下、没有发出 ⇒ 不加 "Create failed:" 前缀。
@Suite("creation(.runtimeTooOldForRemoteImage)：文案 / 分类 / 日志名")
struct RuntimeTooOldForRemoteImageTests {

    static let error = RuntimeError.creation(.runtimeTooOldForRemoteImage(running: RuntimeVersion(major: 1, minor: 6, patch: 0)))
    static let en = Locale(identifier: "en")
    static let englishText =
        "The running container runtime (1.6.0) can't create from an image that hasn't been pulled yet. Pull the image first, or update the runtime."

    @Test("create 提交被挡：专用文案带出运行中版本，不说 failed")
    func createMessage() {
        let text = ContainerCreationPresentation.message(for: ContainerCreationStore.Failure.createFailed(Self.error), locale: Self.en)
        #expect(text == Self.englishText)
        #expect(!text.localizedCaseInsensitiveContains("failed"))
    }

    @Test("clone 提交被挡：同一句")
    func cloneMessage() {
        #expect(
            ContainerCreationPresentation.message(for: ContainerCloneStore.SubmitFailure.createFailed(Self.error), locale: Self.en)
                == Self.englishText
        )
    }

    @Test("四语有译文且带出版本", arguments: ["ja", "zh-Hans", "zh-Hant"])
    func translated(language: String) {
        let text = ContainerCreationPresentation.message(
            for: ContainerCreationStore.Failure.createFailed(Self.error), locale: Locale(identifier: language)
        )
        #expect(!text.isEmpty && text != Self.englishText, "\(language)")
        #expect(text.contains("1.6.0"), "\(language)：版本要带出来")
    }

    /// 重试不会改变运行中 server 的版本 ⇒ `.permanent`。create 不在 supervisor 路径上，D4 无涉；
    /// 关键是**不**落进 `.transient`（那一档计入熔断）。
    @Test("分类为 permanent（不计入熔断）")
    func classifiedPermanent() {
        #expect(FailureKind(from: Self.error) == .permanent)
    }

    @Test("日志公开名")
    func publicKind() {
        #expect(OSLogSupervisorLog.publicKind(Self.error) == "creationRuntimeTooOldForRemoteImage")
    }
}
