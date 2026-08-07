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

    /// **隔离写进类型。** 它碰 `model.whitelist`，本来就只能在主线程调。
    ///
    /// ★ **这个标注和下面 `set:` 的字面闭包是两件正交的事，别以为删一个另一个会报警**
    /// （实测：去掉本标注、保留字面闭包 → 编译零警告零错误）：
    /// - `set:` 的字面闭包负责**消除** `@isolated(any) @Sendable` 转换警告，并绕开 F6 崩溃；
    /// - 本标注负责**把隔离写进类型**——使非 MainActor 的同步直接调用成为编译错误。
    ///
    /// 所以删掉本标注是**静默**失去类型保证：不报警、不报错、测试全绿。
    /// 守它的不是编译警告，是 `Scripts/check-mainactor-callbacks.sh` 的 compile-fail fixture。
    let onToggleManaged: @MainActor (Bool) -> Void

    /// 打开这个容器的详情窗口（env 在那儿逐行打码显示）。
    let onShowDetail: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // ★ `set:` 必须是**隐式推断隔离**的字面闭包，不能写成 `set: onToggleManaged`，
            // 也不能写成 `set: { @MainActor value in … }`——两种写法都会让 Swift 6.3.3 的
            // IRGen 崩溃（thunk `@$sSbScA_pSgIeAghyg_SbIeAghn_TR`，signal 6，编译期就炸）。
            // 触发条件是「源类型在类型层面显式携带 @MainActor」→ 转 `@isolated(any) @Sendable` 的
            // reabstraction thunk。这里的闭包隔离由编译器推断（body 在 @MainActor 上、且它同步
            // 调用 @MainActor 的 onToggleManaged），SE-0431 保证转成 @isolated(any) 时动态保留该隔离。
            // 详见 Docs/plans/2026-08-07-sendable-isolation-fix.md 的 F6。**别顺手简化这一行。**
            Toggle("", isOn: Binding(get: { isManaged }, set: { onToggleManaged($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                // `.help` 是补充说明，**不是名称**：读屏念的是名称，念不到 help。
                // 空 label + labelsHidden 让这个勾选框在 AX 树上三条名称信道全空
                // （P1-D 实测），读屏只念「复选框，未选中」——而它就是白名单开关本身。
                // 名字必须带容器 id：一屏多行，不带 id 的话每一行念出来完全一样。
                .accessibilityLabel(Text("Auto-start \(container.id.rawValue) after the runtime restarts"))
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
            // SF Symbol 给的默认名（"Info"）同窗内每一行都一样，读屏分不清点的是哪个容器。
            .accessibilityLabel(Text("Details for \(container.id.rawValue)"))
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
