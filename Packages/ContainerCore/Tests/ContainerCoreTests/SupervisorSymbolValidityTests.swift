import AppKit
import Foundation
import Testing

@testable import ContainerCore

/// 菜单栏图标的**可渲染性**守卫：符号名必须真的能变成像素。
///
/// ## 为什么「非空」不够——这个 bug 就是从那道缝里活下来的
///
/// `SupervisorPresentationTests.everyStateHasHeadline` 早就遍历了所有状态断言
/// `symbol(for:)` 非空，它一直全绿；而 v0.3.2 的菜单栏在 5 个状态里有 3 个
/// **完全不可见**：`shippingbox.badge.xmark` / `shippingbox.badge.plus`
/// 在 macOS 26 上根本不存在。
///
/// SwiftUI 的 `Image(systemName:)` 对不存在的符号**不报错、不 log**，渲染成空白。
/// 于是编译绿、测试绿、进程活着、AX 甚至照报 `x=1344 w=18 h=24` 的 frame——
/// 四个信号全在骗人，唯一的真信号是肉眼看菜单栏那一格是空的。
///
/// 「字符串非空」守的是**有没有人填**；「NSImage 非 nil」守的才是**填的东西成不成立**。
/// 靶子差一格，守卫就是装饰。
///
/// ## 边界（别越界解读）
///
/// 守的是「符号在**当前构建机的** SF Symbols 目录里存在」。**不守**运行机器——
/// 用户的 macOS 若比构建机旧，新符号一样会渲染成空白。真要覆盖那条，得给符号
/// 标注最低系统版本；当前 App 的部署目标是 macOS 15+，构建机 26.5.2，
/// 这道缝还开着，登记在此。
@Suite("菜单栏符号必须真实存在")
struct SupervisorSymbolValidityTests {

    private static let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)

    /// 每个 case 一个代表值。
    ///
    /// ★ 光有这张表不够：将来加了 case 却忘了往表里加样本，测试照样全绿——
    /// 新状态的图标就没人守了。`exhaustivenessWitness` 那个 switch 是配套的另一半，
    /// 它会在加 case 时**编译不过**，逼人回到这里。两段缺一不可。
    private static let allStates: [SupervisorState] = [
        .unknown,
        .runtimeDown,
        .runtimeUp(generation: g1, baseline: true),
        .runtimeUp(generation: g1, baseline: false),
        .reconciling(generation: g1, failures: nil),
        .cooldown(
            generation: g1,
            until: Date(timeIntervalSince1970: 10),
            failures: FailureStreak(attempts: 2, breakerFailures: [])
        ),
        .circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 0)),
    ]

    /// 新增 `SupervisorState` 的 case 时，这个 switch 编译不过。
    /// 它不做任何断言——它的全部价值就是**不让人绕过上面那张样本表**。
    private static func exhaustivenessWitness(_ state: SupervisorState) {
        switch state {
        case .unknown, .runtimeDown, .runtimeUp, .reconciling, .cooldown, .circuitOpen:
            break
        }
    }

    @Test("每个状态的图标都能被 SF Symbols 解析出来")
    func everySymbolResolves() {
        for state in Self.allStates {
            let name = SupervisorPresentation.symbol(for: state)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)

            #expect(
                image != nil,
                """
                SF Symbol \"\(name)\" 在本机不存在 —— 菜单栏那一格会渲染成空白，
                App 在状态 \(state) 下从菜单栏上消失。
                """
            )
        }
    }
}
