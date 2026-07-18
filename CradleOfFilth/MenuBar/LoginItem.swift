import Observation
import ServiceManagement

/// 登录自启。**这是核心场景的前提，不是可选的便利功能。**
///
/// 场景是「Mac 重启 → apiserver 起来 → 容器不会自己回来」。要看见 `.runtimeDown → running`
/// 这条边沿，App 必须**在 apiserver 起来之前或同时**就已经在跑。等用户手动去点开一个
/// 菜单栏 App，那条边沿早就过去了——supervisor 只会看到「运行时本来就在跑」
/// （`.unknown` → baseline），然后**什么都不做**（冷启动不代劳，PLAN 已拍板）。
///
/// 换句话说：**没开登录自启，这个 App 的核心价值在最重要的那一次不会生效。**
///
/// ## 它为什么这么薄
///
/// `SMAppService` 在开发期和分发期行为不同（未签名 / 未公证的构建注册会失败），
/// 而那**不是我们能测的东西**。所以这里一个判断都不做：只转发，成功与失败原样交给 UI。
@MainActor
@Observable
final class LoginItem {

    private let service = SMAppService.mainApp

    /// 注册失败的原因。**必须能被看见**——静默失败的话，用户以为开了自启，
    /// 而下次 Mac 重启时 App 根本没起来：核心场景当场失效，且没有任何提示。
    private(set) var error: String?

    /// **缓存，不是每次读都问 launchd。**
    ///
    /// `service.status` 是一次同步 IPC。把它写成 `var isEnabled { service.status == .enabled }`
    /// 的话，SwiftUI 每次求值 body 都会打一次 launchd——而 supervisor 每 2 秒推一次状态，
    /// body 就跟着重算，于是一个「几乎永远不变」的开关被以心跳频率反复询问。
    ///
    /// 用户可能在「系统设置 → 登录项」里关掉它，所以菜单每次打开时 `refresh()` 一次。
    private(set) var isEnabled = false

    init() {
        refresh()
    }

    /// 菜单打开时调一次——那正是用户可能刚从系统设置里改完回来的时刻。
    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }

            error = nil
        } catch {
            self.error = error.localizedDescription
        }

        // 注册成功与否，以 launchd 的说法为准——**不是以「我们刚才调用了 register」为准**。
        // 未签名的开发构建上，register() 抛错和「注册了但没生效」都会发生。
        refresh()
    }
}
