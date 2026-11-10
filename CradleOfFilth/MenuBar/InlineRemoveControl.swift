import ContainerCore
import SwiftUI

/// 菜单 popover 里「从白名单移除一条」的**行内两步确认**：垃圾桶 → 原地变成 Remove + Cancel。
///
/// ## 为什么不用 `.confirmationDialog`
///
/// 在 MenuBarExtra 的 popover 里，确认框（挂在 popover 上的 sheet）**用真鼠标点「删除」会让整个菜单收起、
/// 动作不执行**，重开菜单确认框还挂着（v0.4.5 用户实测；AXPress 正常）。根因 TBD——让 activationHealer
/// 放过 sheet 的实验未修好。所以 popover 里不再弹任何东西（Plan 2026-11-10-inline-remove-confirm）。
///
/// ## 布局是防误删的一部分
///
/// Cancel 固定占**原垃圾桶的槽位**、Remove 在它左边：在垃圾桶上连点两下，第二下落在 Cancel 上，不会直接删。
///
/// 无状态：pending 由父视图持有（两个区块共用一个，一次只有一行在确认）。
struct InlineRemoveControl: View {

    let id: ContainerID
    let isPending: Bool
    let onBegin: @MainActor () -> Void
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        if isPending {
            HStack(spacing: 10) {
                Button("Remove", role: .destructive) { onConfirm() }
                    .accessibilityLabel(Text("Remove \(id.rawValue) from the whitelist"))
                    .help("Remove \(id.rawValue) from the whitelist")
                Button("Cancel") { onCancel() }
                    .accessibilityLabel(Text("Cancel removing \(id.rawValue) from the whitelist"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } else {
            // `role: .destructive` 与 Images / Volumes / 容器详情同类触发按钮一致（AX trait 与配色）。
            Button(role: .destructive) { onBegin() } label: {
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            // ★ 这一下只是「请求确认」，名字不能说成已经在删；且必须带 id（每行一颗，P2-E 的教训）。
            .accessibilityLabel(Text("Ask before removing \(id.rawValue) from the whitelist"))
            .help("Ask before removing \(id.rawValue) from the whitelist")
        }
    }
}
