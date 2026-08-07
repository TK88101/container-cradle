import Foundation
import Testing

@testable import ContainerCore

/// T9.4b：`RuntimeErrorPresentation.detail` —— `RuntimeError` 的技术详情文案**单点**。
///
/// 它是从 `ContainerActionPresentation.detail`（private）抽出来的：Day 16 B 段出现了
/// 第三、第四个消费者（creation / pull presentation），这才是 DRY 的正确触发点。
/// 把 helper 继续挂在 action 上会让后续 presentation 反向依赖「动作」这个不相干的概念。
///
/// **`RuntimeDownBanner`（app target）的第二份刻意不合并**——那是语境分叉
/// （持久横幅补一句「挂上后自动重试」，这里的瞬时错误行不补），既有注释已登记。
@Suite("RuntimeErrorPresentation 技术详情文案")
struct RuntimeErrorPresentationTests {

    private let locale = Locale(identifier: "en")

    @Test("四个 case 各有非空文案，且互不相同（防复制粘贴漏改）")
    func allCasesDistinctAndNonEmpty() throws {
        let messages = [
            RuntimeErrorPresentation.detail(.runtimeUnavailable, locale: locale),
            RuntimeErrorPresentation.detail(.containerNotFound(try #require(ContainerID("web"))), locale: locale),
            RuntimeErrorPresentation.detail(.mountSourceUnavailable(path: "/Volumes/ext"), locale: locale),
            RuntimeErrorPresentation.detail(.operationFailed(reason: "boom"), locale: locale),
        ]

        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
    }

    @Test("containerNotFound 文案含容器 id")
    func notFoundNamesTheContainer() throws {
        let message = RuntimeErrorPresentation.detail(
            .containerNotFound(try #require(ContainerID("web"))),
            locale: locale
        )
        #expect(message.contains("web"))
    }

    @Test("mountSourceUnavailable 文案含宿主路径")
    func mountSourceNamesThePath() {
        let message = RuntimeErrorPresentation.detail(
            .mountSourceUnavailable(path: "/Volumes/ext"),
            locale: locale
        )
        #expect(message.contains("/Volumes/ext"))
    }

    /// `.operationFailed` 的 reason 是 runtime 层的英文诊断串，**原样透传不翻译**
    /// （Day 14 §1：技术详情保持可搜索）。翻译它 = 用户再也搜不到上游的错误。
    @Test("operationFailed 的 reason 原样透传，不翻译不加壳")
    func operationFailedPassesReasonVerbatim() {
        let reason = "failed to bootstrap: exit status 125"
        #expect(RuntimeErrorPresentation.detail(.operationFailed(reason: reason), locale: locale) == reason)
        // 换个 locale 也仍是原样——透传不受语言影响。
        #expect(
            RuntimeErrorPresentation.detail(
                .operationFailed(reason: reason),
                locale: Locale(identifier: "zh-Hans")
            ) == reason
        )
    }

    /// **纯搬家的证据**：抽取后 `ContainerActionPresentation` 的输出必须逐字包含
    /// 同一份 detail —— 否则「重构」悄悄改了用户看到的文案。
    @Test("抽取是纯搬家：action 文案仍逐字包含同一份 detail")
    func actionPresentationStillUsesTheSameDetail() {
        let detail = RuntimeErrorPresentation.detail(.runtimeUnavailable, locale: locale)
        let actionMessage = ContainerActionPresentation.message(
            for: .deleteFailed(.runtimeUnavailable),
            locale: locale
        )
        #expect(actionMessage.contains(detail))
    }
}
