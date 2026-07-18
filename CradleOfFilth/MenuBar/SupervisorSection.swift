import ContainerCore
import SwiftUI

/// supervisor 在菜单里的那一块：**它现在在干什么，以及唯一的人工出口。**
///
/// 「立即启动受管容器」**常驻**，不是只在熔断时才出现——它是 R3/R8 的兜底
/// （任何自动状态机都有它没想到的局面），也是**熔断的唯一复位手段**。
/// 只在熔断时才显示的话，用户在别的卡住的局面里就没有出口了。
struct SupervisorSection: View {

    let state: SupervisorState
    let notice: SupervisorNotice?
    let onForceReconcile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: SupervisorPresentation.symbol(for: state))
                    .foregroundStyle(isAlarming ? Color.orange : Color.secondary)

                Text(SupervisorPresentation.headline(for: state))
                    .font(.callout)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            // 「上次为什么失败」。笼统的「启动失败」会让用户去翻日志；
            // 「等待挂载源就绪（外置盘还没挂上？）」让他去插硬盘。
            if let detail = SupervisorPresentation.detail(for: notice) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isAlarming ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("立即启动受管容器", action: onForceReconcile)
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 判断在 `SupervisorPresentation` 里（那儿有测试），这里只是转发。
    private var isAlarming: Bool { SupervisorPresentation.isAlarming(state) }
}
