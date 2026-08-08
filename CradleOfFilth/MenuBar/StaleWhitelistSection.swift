import ContainerCore
import SwiftUI

/// 白名单里那些**容器已经不存在**的条目，以及它们唯一的出口。
///
/// ## 为什么需要这一块
///
/// 上面那排勾选框是按**容器列表**渲染的。容器一旦被删掉，它在白名单里的条目就此
/// 从界面上消失——看不见、也没法取消勾选，只能去 Finder 手改 JSON。
/// `enabled=false` 的那种对 supervisor 是惰性的（不会被拉起），但 `enabled=true` 的
/// 会一直触发「白名单里有容器不存在」的系统通知，而用户在界面上找不到任何地方处理它。
///
/// ## 什么时候**不**显示
///
/// 孤儿集合由 `WhitelistOrphanPolicy` 算，运行时不可信时它返回空集，于是本区块整个消失。
/// 这不是「顺便优化」：`container system stop` 之后每一条白名单看起来都是孤儿，
/// 此时若把它们列出来说「这些失效了」，用户点几下就把整份配置清空了——
/// 而那正是这个 App 唯一该活着的时刻。
///
/// ## 为什么有确认对话框，又为什么只到这一档
///
/// 白名单是配置资产，一键永久删除该有个确认。但**只到确认这一档为止**：
/// 删 volume 要求用户手打卷名（那是加密后不可恢复的数据），这里删错了重新勾一次就回来。
/// 把两者做成一样重，只会让人养成盲目点确认的习惯，反而削弱 volume 那道真正的防线。
struct StaleWhitelistSection: View {

    let entries: [WhitelistEntry]

    /// 隔离写进类型：它会去改配置文件，只能从主线程上的那颗按钮触发。
    let onRemove: @MainActor (ContainerID) -> Void

    @State private var pendingRemoval: ContainerID?

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stale whitelist entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("These containers no longer exist, so they will never start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(entries, id: \.id) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .confirmationDialog(
                Text("Remove \(pendingRemoval?.rawValue ?? "") from the whitelist?"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    // 校验不在这里——它在 `StaleWhitelistRemoval.perform`（core，可测），
                    // 那边先刷新再判定。这里只负责把意图递过去。
                    if let id = pendingRemoval { onRemove(id) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("The container is gone. Removing the entry only edits your whitelist.")
            }
        }
    }

    private func row(_ entry: WhitelistEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.id.rawValue)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            // `role: .destructive` 与 Images / Volumes / 容器详情三处同类触发按钮一致：
            // 它同时决定 AX trait 与配色，漏掉这一处会让读屏对「同样是删」的四个入口说法不一。
            Button(role: .destructive) {
                pendingRemoval = entry.id
            } label: {
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            // ★ 名称必须带 id：这一块里每行都是一颗 Remove 按钮，
            //   读屏用户听到三遍「移除」分不清哪一行——那等于没说（P2-E 的教训）。
            .accessibilityLabel(Text("Remove \(entry.id.rawValue) from the whitelist"))
            .help("Remove \(entry.id.rawValue) from the whitelist")
        }
    }
}
