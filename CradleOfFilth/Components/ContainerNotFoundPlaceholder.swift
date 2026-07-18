import SwiftUI

/// 「找不到这个容器」占位 view。三个窗口宿主共用同一句话——`ContainerDetailHost` /
/// `LogWindowHost` / `StatsWindowHost` 原本各自拷贝一份 `ContentUnavailableView`，
/// 只有 `systemImage` 和 `frame` 不同。窗口按 id 现查，列表可能在窗口开着时被刷新掉
/// （容器被删、运行时不在了）——三处宿主都要老实说，而不是渲染一份陈旧的内容。
struct ContainerNotFoundPlaceholder: View {

    let systemImage: String
    let minWidth: CGFloat
    let minHeight: CGFloat

    var body: some View {
        ContentUnavailableView(
            "Container not found",
            systemImage: systemImage,
            description: Text("The list may have refreshed, or the runtime is gone.")
        )
        .frame(minWidth: minWidth, minHeight: minHeight)
    }
}
