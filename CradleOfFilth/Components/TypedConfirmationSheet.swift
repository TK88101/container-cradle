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
    /// 隔离写进类型：破坏性动作的确认回调，只由主线程上的按钮触发。
    /// （闭包体内起不起 `Task` 与它自身的隔离契约无关——调用点 `VolumesWindowView:159`
    /// 正是 `{ typed in Task { await … } }`，`Task` 起在闭包**内部**。）
    let onConfirm: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

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

            Text("This action cannot be undone. Type \(Text(expectedName).font(.system(.body, design: .monospaced)).bold()) to confirm.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Type the name here", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                // 这个框是**不可恢复删除**的唯一闸门，而它不在 `Form` 里 → 无名。
                // 上面那句「Type X to confirm」是 StaticText，读屏不会替这个框念它；
                // 名字里带上要打的名字，用户不必来回跳读也知道该敲什么。
                .accessibilityLabel(Text("Type \(expectedName) to confirm"))
                .autocorrectionDisabled()

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
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
        title: "Delete Volume",
        expectedName: "openconnector-data",
        destructiveLabel: "Delete",
        details: ["Volume: openconnector-data", "Used: 70.1 MB", "Data cannot be recovered."],
        onConfirm: { _ in },
        onCancel: {}
    )
}
