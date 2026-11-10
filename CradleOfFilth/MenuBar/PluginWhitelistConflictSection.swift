import ContainerCore
import SwiftUI

/// 白名单里那些**指向插件管理容器**的条目（Day 29）。
///
/// 只可能来自升级前勾过的历史条目（现在勾选框对它们禁用）。supervisor 每一轮都跳过它们、不算失败——
/// 于是「已配置却永远不会被拉起」这件事只能在这里被看见。**不自动删**：条目是用户的配置资产。
///
/// 与 `StaleWhitelistSection` 同形（同一档、行内确认），刻意不合并：两者告诉用户的事不同（容器没了 / 容器归插件管）。
struct PluginWhitelistConflictSection: View {

    let conflicts: [WhitelistPluginConflict]

    /// 正在等确认的那一条（父视图持有，与失效条目区块共用；见 `InlineRemoveControl`）。
    let pendingRemoval: ContainerID?
    let onPendingChange: @MainActor (ContainerID?) -> Void

    let onRemove: @MainActor (ContainerID) -> Void

    var body: some View {
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Whitelist entries the supervisor skips")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("These containers are managed by a plugin, so the supervisor will not start them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(conflicts, id: \.entry.id) { conflict in
                    row(conflict)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func row(_ conflict: WhitelistPluginConflict) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(conflict.entry.id.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PluginOwnerCaption(owner: conflict.owner, style: .orange)
            }

            Spacer(minLength: 0)

            // 校验在 core（`PluginWhitelistConflictRemoval.perform`：先刷新再判定）。
            InlineRemoveControl(
                id: conflict.entry.id,
                isPending: pendingRemoval == conflict.entry.id,
                onBegin: { onPendingChange(conflict.entry.id) },
                onConfirm: { onPendingChange(nil); onRemove(conflict.entry.id) },
                onCancel: { onPendingChange(nil) }
            )
        }
    }
}
