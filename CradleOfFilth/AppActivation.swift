import AppKit

/// LSUIElement App 的激活协议（Day 11）。
///
/// ## 为什么存在
///
/// macOS 14+ 的协作式激活下，accessory App 从进程内调 `NSApp.activate()` 会被**直接拒绝**
/// （Day 11 真机 lldb 实测：调用返回、`isActive` 依旧 false、前台纹丝不动），
/// `activate(ignoringOtherApps: true)` 的参数从 macOS 14 起就是 no-op。
/// 于是「打开窗口前先激活自己」全都没真的激活——App 的窗口开着、字段能标记 focused，
/// 键盘事件（Cmd-C、搜索框、删卷确认）却全部落进**上一个活跃 App**。
/// 用户看到的症状是「复制 / 输入无效」，而界面上没有任何异常。
///
/// ## 修法
///
/// 自我激活必须走 **LaunchServices**（对自己的 bundle `openApplication`，
/// `configuration.activates = true`）——这是 `open -a` 和 AppleScript `activate`
/// 的同一条路，协作式激活对它放行；进程内的 `NSApp.activate()`（含 `.regular`
/// policy 舞步）在活跃事件上下文里都会被拒（真机 lldb 对照实测）。
/// App 始终保持 `.accessory`，Dock 永不出现图标。
@MainActor
enum AppActivation {

    /// 需要键盘的窗口交互时调用（开窗、点进已开的窗）。已激活时是幂等 no-op。
    ///
    /// 两个实现细节都是真机踩出来的：
    /// - **推迟一个 runloop**：在 MenuBarExtra popover 的按钮 action 里同步做激活，
    ///   会把 popover 的关闭和 `openWindow` 的场景处理搅在一起——实测窗口根本没建出来。
    /// - **走 LaunchServices（对自己 `openApplication`），不走 `NSApp.activate()`**：
    ///   后者在活跃事件上下文里被协作式激活按住（lldb 静止上下文同一调用却放行），
    ///   `.regular` policy 舞步也一样被拒。LS 这条路等价于 `open -a` / AppleScript 的
    ///   `activate`——取证期间它**每一次**都被放行。
    static func activateForWindowUse() {
        DispatchQueue.main.async {
            guard !NSApp.isActive else { return }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            )
        }
    }}
