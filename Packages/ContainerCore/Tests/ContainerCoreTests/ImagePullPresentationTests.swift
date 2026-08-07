import Foundation
import Testing

@testable import ContainerCore

/// T9.5：pull 的失败文案与状态标签。进度**数值**仍走已有的 `PullProgress.display`
/// （三档降级已测），这里只管「这一行状态用什么话说」。
@Suite("ImagePullPresentation 拉取文案")
struct ImagePullPresentationTests {

    private let en = Locale(identifier: "en")
    private let zh = Locale(identifier: "zh-Hans")

    private func ref(_ raw: String) throws -> ImageRef { try #require(ImageRef(raw)) }

    // MARK: - FailureKind

    @Test("FailureKind：两个通道文案非空且不同（建流失败 vs 流内失败是不同处境）")
    func failureKindsDistinct() {
        let setup = ImagePullPresentation.message(for: .setup(.runtimeUnavailable), locale: en)
        let stream = ImagePullPresentation.message(for: .stream("connection reset"), locale: en)
        #expect(!setup.isEmpty)
        #expect(!stream.isEmpty)
        #expect(setup != stream)
    }

    /// 两个通道的技术详情都要**原样透传**：`setup` 走 `RuntimeErrorPresentation`
    /// （`.operationFailed` 原样），`stream` 是 `localizedDescription` 字符串。
    /// 翻译掉它们 = 用户再也搜不到上游的错误。
    @Test("技术详情原样透传（setup 走 RuntimeErrorPresentation，stream 原串）")
    func technicalDetailIsVerbatim() {
        #expect(
            ImagePullPresentation.message(for: .setup(.operationFailed(reason: "no such image")), locale: en)
                .contains("no such image")
        )
        #expect(
            ImagePullPresentation.message(for: .stream("connection reset by peer"), locale: en)
                .contains("connection reset by peer")
        )
    }

    @Test("FailureKind：zh-Hans 有译文（非 key 回显）")
    func failureKindsTranslated() {
        for kind in [ImagePullStore.FailureKind.setup(.runtimeUnavailable), .stream("boom")] {
            let localized = ImagePullPresentation.message(for: kind, locale: zh)
            let english = ImagePullPresentation.message(for: kind, locale: en)
            #expect(localized != english, "未翻译（key 回显）：\(english)")
        }
    }

    // MARK: - State 标签

    private func allStates() throws -> [ImagePullStore.State] {
        [
            .idle,
            .pulling(reference: try ref("nginx:latest"), progress: nil),
            .cancellingForeground(reference: try ref("nginx:latest")),
            .failed(reference: try ref("nginx:latest"), kind: .stream("boom")),
            .done(reference: try ref("nginx:latest")),
        ]
    }

    @Test("State：五态标签非空且互不相同")
    func stateLabelsDistinct() throws {
        let labels = try allStates().map { ImagePullPresentation.statusLabel(for: $0, locale: en) }
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
    }

    /// `.cancellingForeground` 是本仓刻意的语义：**前台放弃 ≠ 后台停止下载**
    /// （A 段规定 `cancel()` 不调 `onCompleted`，运行时那边也管不到）。
    ///
    /// 断言的是**实质不变式**：标签必须保留「可能仍在下载」这个 hedge。
    /// 不用「禁某个关键词」那种粗判据——「Stopped **waiting**」恰恰是正确措辞，
    /// 禁 `stopped` 会把对的实现判红（第一版就这么误伤了自己）。
    @Test("cancellingForeground 标签必须保留「后台可能仍在下载」的 hedge")
    func cancellingLabelKeepsTheHedge() throws {
        let label = ImagePullPresentation.statusLabel(
            for: .cancellingForeground(reference: try ref("nginx:latest")),
            locale: en
        ).lowercased()
        #expect(label.contains("still"))
        #expect(label.contains("downloading"))
    }

    @Test("pulling / done 标签含镜像 ref（用户要知道在拉哪个）")
    func labelsNameTheImage() throws {
        #expect(
            try ImagePullPresentation.statusLabel(
                for: .pulling(reference: try ref("nginx:latest"), progress: nil), locale: en
            ).contains("nginx:latest")
        )
        #expect(
            try ImagePullPresentation.statusLabel(
                for: .done(reference: try ref("nginx:latest")), locale: en
            ).contains("nginx:latest")
        )
    }

    @Test("State：zh-Hans 全部有译文（非 key 回显）")
    func stateLabelsTranslated() throws {
        for state in try allStates() {
            let localized = ImagePullPresentation.statusLabel(for: state, locale: zh)
            let english = ImagePullPresentation.statusLabel(for: state, locale: en)
            #expect(localized != english, "未翻译（key 回显）：\(english)")
        }
    }
}
