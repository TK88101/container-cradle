import ContainerCore
import SwiftUI

/// 列表里的一行容器。
///
/// **不渲染 env。** 详情页（M3）才渲染，且必须走 `SecretField`（打码 → 点击展开 →
/// concealed pasteboard）。在这里顺手显示 env，等于让密钥出现在每一次「点开菜单」的截图里。
struct ContainerRow: View {

    let container: Container

    /// 运行时挂了之后仍在显示的旧数据。灰掉，让「这不是当前状态」一眼可见——
    /// 显示陈旧数据而不标明它陈旧，比不显示更糟。
    let isStale: Bool

    /// **这个勾选框就是白名单。** 勾上 = 运行时回来时把它自动拉起来。
    ///
    /// 它长在列表行上、而不是藏在某个「设置」窗口里，是刻意的：
    /// 自动拉起是这个 App 存在的理由，它该在最显眼的地方。
    let isManaged: Bool

    let onToggleManaged: (Bool) -> Void

    /// 打开这个容器的详情窗口（env 在那儿逐行打码显示）。
    let onShowDetail: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isManaged }, set: onToggleManaged))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Managed by supervisor: auto-started after the runtime restarts")

            Circle()
                .fill(Self.color(for: container.state))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.id.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(container.image.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(ContainerStatePresentation.label(for: container.state))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onShowDetail) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Details (environment variables masked by default)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(isStale ? 0.45 : 1)
    }

    /// 状态颜色**只是提示，不是唯一信道**——右侧永远有文字标签。
    /// 只靠颜色区分状态，色觉障碍用户就读不出这个界面（WCAG 1.4.1）。
    private static func color(for state: ContainerState) -> Color {
        switch state {
        case .running: .green
        case .stopped: .secondary
        case .stopping: .orange
        case .unknown: .yellow
        }
    }
}
