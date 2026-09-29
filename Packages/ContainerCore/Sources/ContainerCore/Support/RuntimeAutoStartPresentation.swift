import Foundation

/// 运行时自动启动的全部上屏文案（Day 23）。判断与措辞住 core（可测）；app 只负责画。
///
/// 标点纪律同 `RuntimeUpdatePresentation`：`failureReason` 一律不带句末标点，句子之间的标点由模板负责。
/// 技术细节（`container system start`、退出码）原样透传不翻译（Day 14 §1：保持可搜索）。
public enum RuntimeAutoStartPresentation {

    /// 横幅上「启动运行时」那一块画什么。`nil` = 整块不画。
    public struct StartBanner: Equatable, Sendable {
        public let status: String?
        public let isStartEnabled: Bool
    }

    /// 横幅的「启动运行时」按钮与状态行（simplify R1 altitude：判断住 core 可测，view 只画）。
    /// - 只在运行时没在跑时出现；
    /// - 副实例不给（它的 starter 拿不到租约，按了只会静默跳过）；
    /// - 更新器那一栏已有复原按钮时让给它（同名按钮两个 = 两个入口写同一目标）；
    /// - 在途 / 退出开始之后按钮禁用。
    public static func startBanner(
        for error: RuntimeError,
        state: RuntimeAutoStarter.State,
        isPrimaryInstance: Bool,
        hasManualRestore: Bool,
        isTerminating: Bool,
        locale: Locale = .current
    ) -> StartBanner? {
        guard case .runtimeUnavailable = error, isPrimaryInstance, !hasManualRestore else { return nil }
        return StartBanner(
            status: statusText(for: state, locale: locale),
            isStartEnabled: state != .starting && !isTerminating
        )
    }

    /// 横幅上的状态行（UI 只从 `starter.state` 派生，codex R2 f）。`idle` 不占行。
    public static func statusText(for state: RuntimeAutoStarter.State, locale: Locale = .current) -> String? {
        switch state {
        case .idle:
            return nil
        case .starting:
            return String(coreLocalized: "Starting the container runtime…", locale: locale)
        case .deferred(let reason):
            return deferralText(reason, locale: locale)
        case .failed(let failure):
            let reason = failureReason(failure, locale: locale)
            return String(coreLocalized: "Could not start the runtime: \(reason)", locale: locale)
        }
    }

    static func deferralText(_ reason: RuntimeAutoStartDeferral, locale: Locale) -> String {
        switch reason {
        case .updaterBusy, .updaterOwesRuntimeStart:
            String(coreLocalized: "A runtime update is in progress; the runtime will start when it finishes", locale: locale)
        case .privilegedJobRunning:
            String(coreLocalized: "A runtime update task is running; will retry shortly", locale: locale)
        case .lockProbeFailed:
            String(coreLocalized: "Could not check whether a runtime update is running; will retry shortly", locale: locale)
        }
    }

    /// 失败原因（**不带句末标点**）。
    public static func failureReason(_ failure: RuntimeAutoStartFailure, locale: Locale = .current) -> String {
        switch failure {
        case .commandFailed(let exitCode):
            String(coreLocalized: "container system start exited with code \(String(exitCode))", locale: locale)
        case .timedOut:
            String(coreLocalized: "timed out", locale: locale)
        case .notInstalled:
            String(coreLocalized: "apple/container is not installed", locale: locale)
        case .notReady:
            String(coreLocalized: "the runtime did not come up", locale: locale)
        case .blockedByUpdater:
            String(coreLocalized: "a runtime update kept it busy", locale: locale)
        }
    }

    /// 启动路径失败的系统通知。用户登录时不看菜单——通知要说清「没起来」和「怎么补救」。
    /// 自动路径不装内核（Plan §2.5）：首次使用缺内核时按钮会装，正文顺带指出。
    public static func failureNotification(_ failure: RuntimeAutoStartFailure, locale: Locale = .current) -> SystemNotificationContent {
        let reason = failureReason(failure, locale: locale)
        return SystemNotificationContent(
            key: "runtimeAutoStart.failed",
            title: String(coreLocalized: "The container runtime did not start", locale: locale),
            body: String(
                coreLocalized: "Reason: \(reason). Open the menu and click Start Runtime to try again (on first use this also installs the kernel).",
                locale: locale
            )
        )
    }
}
