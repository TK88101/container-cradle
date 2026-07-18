import Foundation

/// supervisor 的状态 / 通知 → **给人看的一句话**。
///
/// ## 为什么这几个字符串住在 library 里，而不是 view 里
///
/// 因为它们不是排版，是**判断**。`.environmentNotReady` 该说「等待挂载源就绪
/// （外置盘还没挂上？）」，而不是笼统的「启动失败」——前者让用户去插硬盘，
/// 后者让他去翻日志（`SupervisorNotice.reconcileFailed` 的文档写的就是这一条）。
///
/// 判断放进 view = 零测试（app target 没有测试 target）。这个仓库已经因此漏过一个
/// 「旧刷新覆盖新刷新」的 bug 了。
///
/// Day 14 起 key = 英文源串（en = development language），zh-Hans / zh-Hant / ja
/// 翻译在 core 目录（lproj）；计数类条目的 en 复数在 `en.lproj/Localizable.stringsdict`。
public enum SupervisorPresentation {

    /// 状态行。
    public static func headline(for state: SupervisorState, locale: Locale = .current) -> String {
        switch state {
        case .unknown:
            String(coreLocalized: "Checking runtime…", locale: locale)

        case .runtimeDown:
            String(coreLocalized: "Runtime is not running", locale: locale)

        case .runtimeUp(_, let baseline):
            baseline
                ? String(coreLocalized: "Runtime OK (cold start, hands off)", locale: locale)
                : String(coreLocalized: "Runtime OK · managed containers started", locale: locale)

        case .reconciling:
            String(coreLocalized: "Starting managed containers…", locale: locale)

        case .cooldown(_, _, let failures):
            String(
                coreLocalized: "Start failed, waiting to retry (failed \(failures.attempts) times)",
                locale: locale
            )

        case .circuitOpen:
            String(coreLocalized: "Circuit open · automatic retries stopped", locale: locale)
        }
    }

    /// 菜单栏图标。**熔断必须看得出来**——熔断意味着 supervisor 从此不干活了，
    /// 而它不干活的样子和一切正常一模一样（`SupervisorNotice.circuitOpened` 的文档）。
    /// SF Symbol 名是标识符不是文案，**不本地化**。
    public static func symbol(for state: SupervisorState) -> String {
        switch state {
        case .unknown, .runtimeUp:
            "shippingbox"

        case .runtimeDown:
            "shippingbox.badge.xmark"         // 运行时不在，列表是旧的

        case .reconciling, .cooldown:
            "shippingbox.badge.plus"          // 正在 / 即将拉起

        case .circuitOpen:
            "exclamationmark.triangle.fill"   // 停手了。必须刺眼。
        }
    }

    /// 该不该刺眼。**熔断 = supervisor 已经停手了**，而它停手的样子和一切正常一模一样。
    ///
    /// 这条判断和 `symbol`/`headline` 是同一类东西，所以它也得住在这儿——
    /// 留在 view 里就是零测试（app target 没有测试 target），
    /// 而「熔断了但界面看不出来」这种 bug，正是没人会在肉眼 review 里发现的那种。
    public static func isAlarming(_ state: SupervisorState) -> Bool {
        if case .circuitOpen = state { return true }

        return false
    }

    /// 最近一条通知的人话。`nil` = 没什么好说的。
    public static func detail(for notice: SupervisorNotice?, locale: Locale = .current) -> String? {
        switch notice {
        case nil, .reconcileSucceeded:
            nil

        case .reconcileFailed(_, let kind, let attempt, _):
            String(
                coreLocalized: "\(reason(for: kind, locale: locale)) · retried \(attempt) times",
                locale: locale
            )

        case .circuitOpened(_, let failures):
            String(
                coreLocalized: """
                Failed \(failures) times in a row; automatic retries stopped. \
                Once fixed, choose "Start managed containers now" from the menu.
                """,
                locale: locale
            )

        case .reconcileAbandoned:
            String(
                coreLocalized: """
                A whitelisted container does not exist (typo in the ID? Or was it deleted?). \
                Check the whitelist.
                """,
                locale: locale
            )

        case .forcedReconcileUnavailable:
            String(
                coreLocalized: "No runtime to start containers on — start the apple/container runtime first.",
                locale: locale
            )
        }
    }

    /// 当前 apiserver 的这一代（`nil` = 还没探测过，或探测确认它不在）。
    ///
    /// **static free function，不是 `SupervisorState` 的 instance 便利属性**——`SupervisorState`
    /// 刻意不提供 `.generation`（该文件文档：会把 `reduce` 的穷尽 switch 退化成 `guard let`，
    /// 未来新增 case 时被静默吞掉，而不是编译报错逼人显式决定）。这里同样写成穷尽 switch，
    /// 只是把它从 `AppModel`（未测）搬到这儿（可测）——原来那份判断跟 `headline`/`symbol`
    /// 是同一类东西：留在 app 层就是零测试。
    public static func generation(for state: SupervisorState) -> RuntimeGeneration? {
        switch state {
        case .unknown, .runtimeDown:
            nil
        case .runtimeUp(let generation, _),
             .reconciling(let generation, _),
             .cooldown(let generation, _, _),
             .circuitOpen(let generation, _):
            generation
        }
    }

    /// 失败三分类 → 用户该去做的事。**这三句话不能合并**：
    /// 它们要用户做的事完全不同（插硬盘 / 查容器为什么崩 / 改白名单）。
    static func reason(for kind: FailureKind, locale: Locale = .current) -> String {
        switch kind {
        case .environmentNotReady:
            String(
                coreLocalized: "Waiting for mount source (external disk / network volume not attached yet?)",
                locale: locale
            )

        case .transient:
            String(coreLocalized: "Start failed (container crashes right after boot?)", locale: locale)

        case .permanent:
            String(coreLocalized: "Container not found", locale: locale)
        }
    }
}
