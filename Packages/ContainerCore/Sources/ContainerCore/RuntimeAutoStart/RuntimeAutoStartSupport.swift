import Foundation
import os

/// 谁要起运行时。
public enum RuntimeAutoStartTrigger: String, Sendable {
    /// App 启动（登录项）时一次。受开关与白名单约束，不装内核。
    case appLaunch = "app-launch"
    /// 横幅上的「启动运行时」。用户显式点击：忽略开关与空白名单，允许装内核。
    case userButton = "user-button"
}

/// 终局跳过：这一轮不再尝试。原始值进日志（allowlist，可 `.public`）。
public enum RuntimeAutoStartSkip: String, Sendable {
    case disabled
    case notPrimary = "not-primary"
    /// 白名单没有受管容器：起了运行时也不服务 supervisor（codex R1 #8）。
    case noManagedContainers = "no-managed-containers"
    /// 运行时已经在跑：交给 supervisor（它的边沿检测 / 冷启动 baseline 各管各的）。
    case alreadyRunning = "already-running"
}

/// 暂时互斥：条件解除后再判（codex R1 #2——「互斥」不许变成静默的永久失效）。
public enum RuntimeAutoStartDeferral: String, Sendable {
    case updaterBusy = "updater-busy"
    /// 盘上意图记录真欠「起运行时」：更新器的恢复流程负责起，我们不插手（codex R1 #1）。
    case updaterOwesRuntimeStart = "updater-owes-runtime-start"
    case privilegedJobRunning = "privileged-job-running"
    /// 探锁本身失败：不当成空闲。
    case lockProbeFailed = "lock-probe-failed"
}

/// 起运行时失败。**已失败的 `system start` 不重试**（Plan §2.5）：失败 ⇒ 横幅 + 通知，用户手动再试。
public enum RuntimeAutoStartFailure: Sendable, Equatable {
    case commandFailed(exitCode: Int32)
    case timedOut
    case notInstalled
    /// CLI 退出 0（上游已 ping 通 apiserver）但随后的新鲜探测看不到它。
    case notReady
    /// 延后次数耗尽，更新器一直占着。
    case blockedByUpdater

    /// 日志用的固定形态（无关联文本，可 `.public`）。
    public var logValue: String {
        switch self {
        case .commandFailed(let exitCode): "command-failed(exit=\(exitCode))"
        case .timedOut: "timed-out"
        case .notInstalled: "not-installed"
        case .notReady: "not-ready"
        case .blockedByUpdater: "blocked-by-updater"
        }
    }
}

/// 起运行时要用到的 CLI 能力（`RuntimeCommands` 的窄面，测试注入 fake）。
public protocol RuntimeStarting: Sendable {
    func isRuntimeRunning() async -> Bool
    func privilegedJobState() async -> PrivilegedJobState
    func startRuntime(allowKernelInstall: Bool) async -> CommandOutcome
}

extension RuntimeCommands: RuntimeStarting {}

/// 另一个会起停运行时的人（更新器）一侧的仲裁：租约 + 盘上意图。
@MainActor
public protocol RuntimeOperationArbitrating: AnyObject {
    var isPrimaryInstance: Bool { get }
    var pendingIntentOwesRuntimeStart: Bool { get }
    func tryBeginExternalRuntimeOperation() -> ExternalRuntimeToken?
    func endExternalRuntimeOperation(_ token: ExternalRuntimeToken)
}

extension RuntimeUpdateStore: RuntimeOperationArbitrating {
    /// 读盘上那份（启动时它就是全部真相；恢复一开始就会置 busy，那时租约本就拿不到）。
    public var pendingIntentOwesRuntimeStart: Bool { preferences.intent?.owesRuntimeStart ?? false }
}

// MARK: - 偏好

/// 「启动时自动恢复受管容器」开关。默认开（用户拍板 U1，2026-09-29）。只在 MainActor 上读写。
@MainActor
public protocol RuntimeAutoStartPreferences: AnyObject {
    var isEnabled: Bool { get set }
}

@MainActor
public final class UserDefaultsRuntimeAutoStartPreferences: RuntimeAutoStartPreferences {

    static let key = "runtimeAutoStart.enabled"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

// MARK: - 日志

/// 每一次决定的观测出口（Plan §2.6）：没有它，「重启后为什么没起来」又会无从还原。
/// 与 `RuntimeUpdateLog` 同一套纪律：注入式、非 async、fire-and-forget；唯一的不可信文本（CLI stderr）只准经 `detail` 记成 `.private`。
public protocol RuntimeAutoStartLog: Sendable {
    func skipped(trigger: RuntimeAutoStartTrigger, reason: RuntimeAutoStartSkip)
    func deferred(trigger: RuntimeAutoStartTrigger, reason: RuntimeAutoStartDeferral, attempt: Int)
    func started(trigger: RuntimeAutoStartTrigger, kernelInstall: Bool)
    func succeeded(trigger: RuntimeAutoStartTrigger)
    func failed(trigger: RuntimeAutoStartTrigger, failure: RuntimeAutoStartFailure, detail: String?)
}

/// 生产实现：`log show --predicate 'subsystem == "com.cradleoffilth.supervisor" AND category == "runtime-autostart"'`。
public struct OSLogRuntimeAutoStartLog: RuntimeAutoStartLog {

    private let log: Logger

    public init(subsystem: String = SupervisorLogging.subsystem) {
        self.log = Logger(subsystem: subsystem, category: "runtime-autostart")
    }

    public func skipped(trigger: RuntimeAutoStartTrigger, reason: RuntimeAutoStartSkip) {
        log.notice("skip trigger=\(trigger.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }

    public func deferred(trigger: RuntimeAutoStartTrigger, reason: RuntimeAutoStartDeferral, attempt: Int) {
        log.notice("defer trigger=\(trigger.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)")
    }

    public func started(trigger: RuntimeAutoStartTrigger, kernelInstall: Bool) {
        log.notice("start trigger=\(trigger.rawValue, privacy: .public) kernelInstall=\(kernelInstall, privacy: .public)")
    }

    public func succeeded(trigger: RuntimeAutoStartTrigger) {
        log.notice("finished trigger=\(trigger.rawValue, privacy: .public) outcome=succeeded")
    }

    public func failed(trigger: RuntimeAutoStartTrigger, failure: RuntimeAutoStartFailure, detail: String?) {
        log.error("finished trigger=\(trigger.rawValue, privacy: .public) outcome=\(failure.logValue, privacy: .public) detail=\(Self.privateDetail(detail), privacy: .private)")
    }

    /// 不可信文本（CLI stderr 尾巴）。★ 调用点只准 `.private`——`D1BoundaryTests` 源码扫描守。
    static func privateDetail(_ detail: String?) -> String { detail ?? "" }
}
