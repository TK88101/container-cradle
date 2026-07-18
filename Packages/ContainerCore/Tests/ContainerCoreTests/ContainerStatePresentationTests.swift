import Testing

@testable import ContainerCore

/// 容器状态 → 中文标签。**一个来源，多处用**（ContainerRow / ContainerDetailView 原本各抄一份）。
@Suite("ContainerStatePresentation")
struct ContainerStatePresentationTests {

    @Test(
        "四态各自的标签",
        arguments: [
            (ContainerState.running, "运行中"),
            (ContainerState.stopped, "已停止"),
            (ContainerState.stopping, "停止中"),
            (ContainerState.unknown, "未知"),
        ]
    )
    func label(_ state: ContainerState, _ expected: String) {
        #expect(ContainerStatePresentation.label(for: state) == expected)
    }
}
