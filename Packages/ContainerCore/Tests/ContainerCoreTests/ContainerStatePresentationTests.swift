import Foundation
import Testing

@testable import ContainerCore

/// 容器状态 → 状态标签。**一个来源，多处用**（ContainerRow / ContainerDetailView 原本各抄一份）。
/// Day 14 起断言显式传 locale：en 断源串，zh-Hans 断目录命中（高价值面 exact，codex #5）。
@Suite("ContainerStatePresentation")
struct ContainerStatePresentationTests {

    private let en = Locale(identifier: "en")
    private let zhHans = Locale(identifier: "zh-Hans")

    @Test(
        "四态各自的标签（en 源串）",
        arguments: [
            (ContainerState.running, "Running"),
            (ContainerState.stopped, "Stopped"),
            (ContainerState.stopping, "Stopping"),
            (ContainerState.unknown, "Unknown"),
        ]
    )
    func label(_ state: ContainerState, _ expected: String) {
        #expect(ContainerStatePresentation.label(for: state, locale: en) == expected)
    }

    @Test(
        "四态各自的标签（zh-Hans 目录命中，非 key 回显）",
        arguments: [
            (ContainerState.running, "运行中"),
            (ContainerState.stopped, "已停止"),
            (ContainerState.stopping, "停止中"),
            (ContainerState.unknown, "未知"),
        ]
    )
    func labelZhHans(_ state: ContainerState, _ expected: String) {
        #expect(ContainerStatePresentation.label(for: state, locale: zhHans) == expected)
    }
}
