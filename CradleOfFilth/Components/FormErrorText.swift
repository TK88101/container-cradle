import ContainerCore
import SwiftUI

/// 表单/窗口内的一行错误红字（simcodex R1 收敛：Create/Clone 两个新窗口原各持一份
/// 逐字相同的 private helper，样式注定漂移）。
///
/// `.textSelection(.enabled)` 是刻意的：错误详情常含上游技术信息，用户要能整段复制去搜。
/// 既有的两份变体不在本轮收敛范围（非本轮 diff，登记 P2）：`MenuBarRootView.errorText`
/// （无 textSelection）与 `ContainerDetailView` 的 actionError 内联块（`.callout`）。
struct FormErrorText: View {

    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// 新建 / 克隆提交进行中的提示行（Day 25，Plan 2026-10-22 §2.4）：满 30 s「仍在进行」、超时后「等待结果」。
/// 文案与判定全在 core 的 `ContainerCreationPresentation.progressNote`（可测）；这里只负责每秒重算一次。
///
/// - `.periodic` 而不是 `.explicit`：Day 24 B 实测弹窗里 `.explicit` 过点不重绘（Plan 2026-10-21 附录 B）。
/// - 调用方把它和按钮行放进**同一个** Form 行（`spacing: 0` 的 VStack）：单独作为 Section 的子 view 时，
///   提示为 nil 也会占一行带分隔线的空行（Day 25 T10 观察）。提示为 nil 时闭包里什么都不画，上间距只跟着文字走。
/// - 调用方只在 `isBusy` 时挂它，窗口关了不渲染，periodic 的代价可忽略。
struct CreationProgressNote: View {

    let isConfirming: Bool
    let submittedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let note = ContainerCreationPresentation.progressNote(
                isConfirming: isConfirming,
                submittedAt: submittedAt,
                now: context.date
            ) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }
}
