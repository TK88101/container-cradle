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
public enum SupervisorPresentation {

    /// 状态行。
    public static func headline(for state: SupervisorState) -> String {
        switch state {
        case .unknown:
            "正在检查运行时…"

        case .runtimeDown:
            "运行时未运行"

        case .runtimeUp(_, let baseline):
            baseline ? "运行时正常（冷启动，未代劳）" : "运行时正常 · 受管容器已拉起"

        case .reconciling:
            "正在拉起受管容器…"

        case .cooldown(_, _, let failures):
            "拉起失败，等待重试（已失败 \(failures.attempts) 次）"

        case .circuitOpen:
            "已熔断 · 自动重试已停止"
        }
    }

    /// 菜单栏图标。**熔断必须看得出来**——熔断意味着 supervisor 从此不干活了，
    /// 而它不干活的样子和一切正常一模一样（`SupervisorNotice.circuitOpened` 的文档）。
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
    public static func detail(for notice: SupervisorNotice?) -> String? {
        switch notice {
        case nil, .reconcileSucceeded:
            nil

        case .reconcileFailed(_, let kind, let attempt, _):
            "\(reason(for: kind)) · 已重试 \(attempt) 次"

        case .circuitOpened(_, let failures):
            "连续失败 \(failures) 次，已停止自动重试。修好之后请手动「立即启动受管容器」。"

        case .reconcileAbandoned:
            "白名单里有容器不存在（ID 拼错了？或者容器被删了）。请检查白名单。"

        case .forcedReconcileUnavailable:
            "现在没有运行时可拉——先把 apple/container 的运行时启动起来。"
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
    private static func reason(for kind: FailureKind) -> String {
        switch kind {
        case .environmentNotReady:
            "等待挂载源就绪（外置盘 / 网络卷还没挂上？）"

        case .transient:
            "启动失败（容器起来就崩？）"

        case .permanent:
            "容器不存在"
        }
    }
}
