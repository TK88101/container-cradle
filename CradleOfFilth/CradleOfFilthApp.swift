import AppKit
import ContainerCore
import SwiftUI

/// 菜单栏 App 的入口。
///
/// ## 为什么要 `NSApplicationDelegate`，而不是在 `MenuBarExtra` 的 `.task` 里启动 supervisor
///
/// 因为 `MenuBarExtra` 的内容**只在菜单被点开时才存在**。把 supervisor 挂在那儿，
/// 它就只在用户看着的时候工作——而这个 App 的全部价值恰恰是**用户没在看的时候它还在盯**
/// （Mac 半夜重启、外置盘慢慢挂上、apiserver 回来、容器被拉起，全程没人在场）。
///
/// `applicationDidFinishLaunching` 是唯一一个「App 起来了、菜单还没被点开」也会跑的地方。
@main
struct CradleOfFilthApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(model: delegate.model)
        } label: {
            // 图标跟着 supervisor 的状态走。**熔断必须一眼看得出来**：
            // supervisor 停手之后的样子和一切正常一模一样——图标不变的话，
            // 用户会以为容器还被守着，直到某天发现它已经停了几个小时。
            Image(systemName: SupervisorPresentation.symbol(for: delegate.model.status.state))
        }
        // `.window` 而非默认的 `.menu`：菜单样式只吃得下 `Button`/`Divider`，
        // 塞不进状态点、勾选框这类自定义排版。
        .menuBarExtraStyle(.window)

        // 容器详情窗口——按 `ContainerID` 打开。env 在这里逐行打码显示（`SecretField`）。
        // 独立 `Window` scene（不是 popover 里的 sheet）：env 列表可能很长，值得一个能拉大的窗口。
        WindowGroup(id: ContainerDetailScene.windowID, for: ContainerID.self) { $id in
            ContainerDetailHost(model: delegate.model, id: id)
        }
        .windowResizability(.contentSize)

        // 日志窗口（Day 9 T7）——follow / 暂停 / 搜索 / 清屏。独立 scene：日志可以长时间
        // 开着，不该跟详情窗共用一个生命周期（关详情不该打断正在跟的日志）。
        WindowGroup(id: LogWindowScene.windowID, for: ContainerID.self) { $id in
            LogWindowHost(model: delegate.model, id: id)
        }
        .windowResizability(.contentSize)

        // stats 窗口（Day 9 T11）——CPU%/内存，打开时把轮询提到 1s，关闭即停。
        WindowGroup(id: StatsWindowScene.windowID, for: ContainerID.self) { $id in
            StatsWindowHost(model: delegate.model, id: id)
        }
        .windowResizability(.contentSize)

        // Volume 管理窗口（Day 10 M5）——单实例 `Window`：volume 是全局资源，不按 ID 开多窗。
        // 双数显示 + 打名字删除（R7 的两道 UI 防线）都在里面。
        Window("Volumes", id: VolumesWindowScene.windowID) {
            VolumesWindowView(model: delegate.model)
        }
        .windowResizability(.contentSize)

        // 镜像管理窗口（Day 10 M5）——infra 镜像已在 ACL 内过滤，这里看不见。
        Window("Images", id: ImagesWindowScene.windowID) {
            ImagesWindowView(model: delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

/// 只做三件事：**App 起来时把 supervisor 开起来，App 退出时把它停掉，
/// 外加一个激活自愈的事件监视器。**
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = AppModel()

    /// 激活自愈（Day 11）。LSUIElement App 的激活是会丢的：MenuBarExtra 的 popover
    /// 关闭时会把激活还给上一个 App；而协作式激活又拒绝 accessory App 的自我激活
    /// （机制与修法见 `AppActivation`）——那时 Cmd-C、搜索框、删卷确认框的键盘输入
    /// 全部去了别家，用户看到的只是「复制无效」。
    ///
    /// 对策不是在每个窗口打开处补激活（那是靠记得），而是钉死一条不变式：
    /// **鼠标点进本 App 的普通窗口时，App 必须是激活的。** local monitor 只看得见
    /// 投递给本进程的事件，所以它天然只管自家窗口；排除 NSPanel 是为了不碰
    /// MenuBarExtra 的 popover（那个 panel 刻意不激活 App，激活反而会让它关闭）。
    /// App 已激活时这里是纯 no-op，幂等。
    private var activationHealer: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activationHealer = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            if !NSApp.isActive, let window = event.window, !(window is NSPanel) {
                // async：等这次点击自身的分发（含 popover 的关闭与激活归还）先落定，
                // 我们的激活请求排在它后面，赢下竞态。
                DispatchQueue.main.async { AppActivation.activateForWindowUse() }
            }

            return event
        }

        Task { await model.start() }
    }

    /// 退出时必须停。**不是洁癖**：在途的 reconcile 若在 App 退出后落地，
    /// 就是「正在退出的 App 把容器拉起来」——Day 5 的 epoch 令牌正是为这一刻加的。
    ///
    /// `applicationWillTerminate` 里没法 `await`（AppKit 不等），所以借
    /// `applicationShouldTerminate` 的 `.terminateLater` 拿一次异步的机会：停干净了再放行。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.stop()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}
