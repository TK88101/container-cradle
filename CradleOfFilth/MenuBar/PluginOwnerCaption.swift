import ContainerCore
import SwiftUI

/// 「由插件 X 管理」那一行小字。三处共用（列表行 / 详情 / 冲突区块）：owner 是上游快照里的**不可信字串**，
/// 展示配方只写一份——core 已单行化 + 截断（`ContainerPluginOwnerPresentation`），这里 verbatim 显示
/// （不当 Markdown / 目录 key 解析）并再兜一层 `lineLimit(1)`。
struct PluginOwnerCaption<Style: ShapeStyle>: View {

    let owner: ContainerPluginOwner
    let style: Style

    var body: some View {
        Text(verbatim: ContainerPluginOwnerPresentation.managedByText(owner))
            .font(.caption)
            .foregroundStyle(style)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
