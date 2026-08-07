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
