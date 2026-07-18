import ContainerCore
import SwiftUI

/// **删除前必须打出名字。** 破坏性操作的门槛组件。
///
/// volume 里可能是加密后不可恢复的数据（Stone Sour 的 OpenConnector 凭证——key 丢了永久解不开）。
/// CLI 的 `down.sh --purge` 都要求打名字确认，GUI 不能比脚本更松。
///
/// **判断不在这儿**：能不能放行由 core 的 `TypedConfirmation.canConfirm` 决定（那儿有测试）。
/// 这个 view 只负责收输入、把判断结果接到删除按钮的 `disabled` 上。
///
/// Day 8 备好、Day 10（M5）接上真实删除路径：`VolumesWindowView` 的删除确认走这里
/// （Images 走 `confirmationDialog`，不用本组件——镜像可重 pull，非「不可挽回」档）。
struct TypedConfirmationSheet: View {

    /// 标题，如「删除 Volume」。
    let title: String

    /// 用户必须原样打出来的名字（volume 名）。
    let expectedName: String

    /// 危险按钮的文字，如「删除」。
    let destructiveLabel: String

    /// 影响面清单（破坏性操作纪律：删除前列影响面）。文案由 core 生成
    /// （`VolumePresentation.deletionImpact`），这里只渲染。
    /// `let` 无默认值（§7 不可变优先）：`let` 带默认值会被 memberwise init 排除，
    /// 调用点就传不进来了——两个调用点（production + Preview）本来就都显式传。
    let details: [String]

    /// 回传用户敲的原文——判断（canConfirm）在这里只管按钮禁用，
    /// **store 侧还会用同一判据再验一次**（防线的第二层）。
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var typed = ""

    private var canConfirm: Bool {
        TypedConfirmation.canConfirm(typed: typed, expected: expectedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            Text("这个操作不可撤销。输入 \(Text(expectedName).font(.system(.body, design: .monospaced)).bold()) 确认。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            TextField("在此输入名字", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()

            HStack {
                Spacer()

                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(destructiveLabel, role: .destructive) { onConfirm(typed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)   // ★ 判断来自 core，打对之前删不了
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

#Preview {
    TypedConfirmationSheet(
        title: "删除 Volume",
        expectedName: "openconnector-data",
        destructiveLabel: "删除",
        details: ["Volume: openconnector-data", "Used: 70.1 MB", "数据不可恢复。"],
        onConfirm: { _ in },
        onCancel: {}
    )
}
