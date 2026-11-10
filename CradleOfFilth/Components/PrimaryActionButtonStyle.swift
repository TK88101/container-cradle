import SwiftUI

/// 视觉 token：「淡化」的透明度。只是一个数值，引用方各有各的语义
/// （主按钮禁用、菜单行数据过期），将来要分开调就各自换常量，不必互相迁就。
enum VisualOpacity {
    static let dimmed: Double = 0.45
}

/// 主按钮 = 系统 `.borderedProminent` + 禁用时降透明度（Plan 2026-11-10）。
/// 为什么要额外降：本 App 的窗口常是非活动样式，prominent 不上强调色，系统禁用变暗与可点几乎无差，
/// `.tint(.gray)` 也看不出（Day 26 T8 实测）。
///
/// 为什么是 ButtonStyle 而不是 ViewModifier：style 在 **Button 所在位置**求值，`.disabled(…)` 写在
/// `.buttonStyle` 之前、之后或挂在祖先上都能读到（Day 27 T4 突变矩阵实测这三种排列）；ViewModifier 读的是
/// 它自己那一层的环境，`.disabled(x).modifier(…)` 会静默不淡。
///
/// 键盘快捷键不在 `PrimitiveButtonStyleConfiguration` 里：给带 role / keyboardShortcut 的按钮用本 style 前另行验证。
struct PrimaryActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DimmedWhenDisabled(configuration: configuration)
    }

    /// `@Environment` 放在 makeBody 返回的 View 里，而不是 style 结构体上：读取点就是按钮自己。
    private struct DimmedWhenDisabled: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(configuration)
                .buttonStyle(.borderedProminent)
                .opacity(isEnabled ? 1 : VisualOpacity.dimmed)
        }
    }
}

extension PrimitiveButtonStyle where Self == PrimaryActionButtonStyle {
    static var primaryAction: PrimaryActionButtonStyle { .init() }
}
