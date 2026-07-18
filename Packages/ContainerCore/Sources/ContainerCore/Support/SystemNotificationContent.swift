import Foundation

/// 一条要弹给用户的**系统通知**的内容 —— 纯值，住 core 所以可测。
///
/// 真正调 `UNUserNotificationCenter` 的薄壳在 app target（`SupervisorNotifier`）。
/// **哪些 notice 该弹、弹什么话、怎么去重**——这些是判断，留在 view / app 层就等于零测试
/// （app target 没有测试 target，这个仓库已经因此漏过 bug）。
public struct SystemNotificationContent: Equatable, Sendable {

    /// **去重身份**。同一个 key 只弹一次（`SupervisorNotifier` 持 `deliveredKeys`）。
    ///
    /// 用**业务身份**而不是 `SupervisorSnapshot.sequence`（codex P1-6）：sequence 是传输序，
    /// 不是「同一次熔断」的身份——store 重新观察、回调重装都会让 sequence 变，却是同一件事。
    /// 而 key 带 generation：运行时换代 = 新的一代 = 一件新的事，key 自然变，于是可以再弹。
    public let key: String

    public let title: String
    public let body: String

    public init(key: String, title: String, body: String) {
        self.key = key
        self.title = title
        self.body = body
    }
}

public extension SupervisorPresentation {

    /// 某条通知该不该弹系统通知，弹的话内容是什么。`nil` = 不弹。
    ///
    /// **只弹「从此不会自动好转、必须人介入」的两条**：
    /// - `.circuitOpened`（熔断：supervisor 从此不再自动重试）
    /// - `.reconcileAbandoned`（放弃：白名单里有容器压根不存在）
    ///
    /// 其余都不弹：`.reconcileFailed` / `.reconcileSucceeded` 是过程态（还在自动重试，弹了就是噪音），
    /// `.forcedReconcileUnavailable` 是用户刚按按钮的即时反馈（菜单里就地说即可）。
    ///
    /// 语义依据见 `SupervisorNotice.circuitOpened` 的文档：熔断不干活的样子和一切正常一模一样，
    /// **只在菜单栏图标变个形不够——用户不会为了看图标而去看菜单栏**。
    static func notification(
        for notice: SupervisorNotice,
        locale: Locale = .current
    ) -> SystemNotificationContent? {
        switch notice {
        case .circuitOpened(let generation, let failures):
            SystemNotificationContent(
                // key 是去重身份（技术标识），不本地化。
                key: "circuitOpened:\(generation.pid)/\(generation.startTime):\(failures)",
                title: String(coreLocalized: "Automatic restart stopped", locale: locale),
                body: String(
                    coreLocalized: """
                    Managed containers failed \(failures) times in a row; the circuit is now open. \
                    Once fixed, choose "Start managed containers now" from the menu.
                    """,
                    locale: locale
                )
            )

        case .reconcileAbandoned(let generation):
            SystemNotificationContent(
                key: "reconcileAbandoned:\(generation.pid)/\(generation.startTime)",
                title: String(coreLocalized: "A whitelisted container is missing", locale: locale),
                body: String(
                    coreLocalized: """
                    A managed container cannot start (typo in the ID? Or was it deleted?). \
                    Check the whitelist.
                    """,
                    locale: locale
                )
            )

        case .reconcileSucceeded, .reconcileFailed, .forcedReconcileUnavailable:
            nil
        }
    }
}

/// 「同一件事只弹一次」的去重器。**住 core 所以可测**——去重是判断，
/// 原本埋在未测的 app 层（`SupervisorNotifier`）里，和 `SupervisorStatusStore.appliedSequence`
/// 一样是「跨投递去重」的模式，那个当初就是为了可测才下沉到 core 的。
///
/// key 带 generation → 换代 = 新的一件事，自然能再弹；同 key 只放行一次。
/// 熔断 / 放弃在实践中稀少，`delivered` 的增长可忽略——**不做淘汰是刻意的简单**。
public struct NotificationDeduplicator {

    private var delivered: Set<String> = []

    public init() {}

    /// 这条内容该不该弹。放行的同时把它记下 → 同 key 第二次问会被拦。
    public mutating func shouldDeliver(_ content: SystemNotificationContent) -> Bool {
        delivered.insert(content.key).inserted
    }
}
