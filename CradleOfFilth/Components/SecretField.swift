import AppKit
import ContainerCore
import SwiftUI

/// 一条密钥的展示：**默认打码，点「显示」才展开，复制走 concealed pasteboard**。
///
/// 这是 D2 在 UI 层的落点，也是整个 App 里**生产代码第一次调 `reveal()`**——所以它被
/// 边界扫描器盯着（app target 的 `plaintextExitBudget` 里登记了它这两处调用点）。
///
/// ## 三条刻意的克制
///
/// 1. **打码用固定长度的点，不用 `secret` 的长度**——长度本身会泄漏信息（密钥多长）。
/// 2. **展开的明文不开 `textSelection`**——否则用户能选中它、`Cmd-C` 进**普通**剪贴板，
///    绕开下面那条 concealed 出口。想复制只有一条路：那个按钮。
/// 3. **复制双写：`.string` + concealed 标记**（Day 11 修正 codex P1-10）——
///    concealed 是给剪贴板管理器看的**附加标记**，不是 `.string` 的替代；
///    只写标记 = 所有粘贴目标读到空，「复制」整个是死的（真机 E1 实测）。
///    写什么由 `ConcealedCopyPayload`（core，有测试）钉死，这里只是誊写。
struct SecretField: View {

    /// 环境变量的 **key**（不是密钥，可明示）。
    let label: String

    let secret: SecretString

    @State private var revealed = false
    @State private var copied = false

    private static let mask = "••••••••"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)

            Text(revealed ? secret.reveal() : Self.mask)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(revealed ? "隐藏" : "显示") { revealed.toggle() }
                .buttonStyle(.borderless)
                .font(.caption)

            Button {
                copyConcealed()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制（走 concealed 剪贴板，不进普通剪贴板历史）")
        }
    }

    private func copyConcealed() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // ★ 双写 .string + concealed 标记——见类型文档第 3 条。条目清单由 core 钉死。
        let allWritten = ConcealedCopyPayload.entries(for: secret.reveal())
            .allSatisfy { entry in
                pasteboard.setString(entry.value, forType: .init(rawValue: entry.type))
            }

        // 对勾只在真写进去时亮：写失败还亮对勾 = 用户以为复制成功，粘出来是旧内容。
        guard allWritten else { return }

        copied = true
        // 图标短暂变对勾再复原：给一个「复制成功」的反馈，不用弹窗。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
