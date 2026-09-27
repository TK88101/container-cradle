import Foundation

/// 这次检查是谁发起的。**跳过只管自动提醒**：用户点「检查更新」是明确意图（Plan A2）。
public enum UpdateTrigger: Sendable, Equatable {
    case automatic
    case manual
}

/// 一次**成功**检查的结论。查询失败 / 限流 / 未安装不在这里——它们在 store 那一层各有各的状态，
/// 这个类型里根本没有能表达「查询失败」的 case，于是「没查到」在结构上不可能被说成 `.upToDate`（Plan §4）。
public enum UpdateDecision: Sendable, Equatable {
    case upToDate(installed: RuntimeVersion)
    case available(installed: RuntimeVersion, release: RuntimeRelease)
    case skipped(installed: RuntimeVersion, release: RuntimeRelease)
}

/// 纯函数：要不要提醒 / 升级，以及自动检查什么时候到期（Day 22 T2）。
public enum UpdatePolicy {

    /// 自动检查的最小间隔。与每小时一次的 tick 相乘：新版本最迟 25 小时内被发现（Plan A1），
    /// 最坏每天 24 次请求——远低于 GitHub 未认证 60 次 / 小时的限额（Plan §5.5）。
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public static func decide(
        installed: RuntimeVersion,
        latest: RuntimeRelease,
        skipped: RuntimeVersion?,
        trigger: UpdateTrigger
    ) -> UpdateDecision {
        // 本机不比 latest 旧（含本机更新的情形）→ 不提示「降级」。
        guard installed < latest.version else { return .upToDate(installed: installed) }

        if trigger == .automatic, skipped == latest.version {
            return .skipped(installed: installed, release: latest)
        }
        return .available(installed: installed, release: latest)
    }

    /// 自动检查是否到期。手动检查不经过这里（它永远可以发）。
    ///
    /// - 开关关着 → 永不到期（A12）；
    /// - 限流期内 → 不到期（解除时刻本身算已解除）；
    /// - 从没成功过、或记录的「上次成功」在未来（时钟被往回调过，那份记录不可信）→ 到期；
    /// - 否则满 `checkInterval` 才到期。
    public static func isCheckDue(
        now: Date,
        lastSuccess: Date?,
        rateLimitedUntil: Date?,
        isEnabled: Bool,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard isEnabled else { return false }
        if let rateLimitedUntil, now < rateLimitedUntil { return false }
        guard let lastSuccess, lastSuccess <= now else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }
}
