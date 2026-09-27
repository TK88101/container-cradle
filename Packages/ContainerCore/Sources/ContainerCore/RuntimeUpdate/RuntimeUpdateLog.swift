import Foundation
import os

/// 更新器每一次 **root 级**动作的观测出口（Day 22，安全评审 L10）。
///
/// 一次升级会以 root 身份装系统软件、停起运行时。事后必须能从统一日志还原：哪一次（nonce）、装什么（目标版本 + digest）、
/// root 说了什么（`COF_RESULT`）、运行时是不是被我们停过（`stopIssued`）、复原成没成。
/// 「不可观测的常驻进程 = 不可信的常驻进程」（CLAUDE.md Day 7/8）对以 root 干活的那一段只会更严。
///
/// 与 `SupervisorLog` 同一套纪律：注入式 protocol（可测）、非 `async`、fire-and-forget；参数全是 domain 值。
/// 唯一的不可信文本（osascript 的 stderr 尾巴、CLI 的诊断输出）只准经 `privateDetail` 记成 `.private`（`D1BoundaryTests` 源码扫描守）。
public protocol RuntimeUpdateLog: Sendable {
    /// 起 osascript 之前（意图记录已写下）。
    func jobStarted(nonce: UUID, target: RuntimeVersion, from: RuntimeVersion, digest: SHA256Digest)
    /// root 已授权且复验通过；`stopIssued` 已写进意图记录、正要 stop。
    func jobReady(nonce: UUID, runtimeWasRunning: Bool, stopIssued: Bool, runningContainers: Int)
    /// root 任务结束（结果只认 root 的输出，AD8）。
    func jobFinished(nonce: UUID, outcome: PrivilegedJobOutcome)
    /// 我们停过的运行时的复原结局。`leftStopped` = 运行时此刻停着（我们停的、没起回来）；`hold` = 没做完的原因（R4 C）；
    /// `startOutcome` 仅在试过 `system start` 时非 nil；`unrestoredContainers` = 还欠着的容器数。
    func restored(nonce: UUID, leftStopped: Bool, hold: RestoreHold, startOutcome: CommandOutcome?, unrestoredContainers: Int)
    /// App 启动时发现上一次的意图记录（AD9）、锁已空闲，开始按状态文件收尾。
    func recovering(nonce: UUID, stopIssued: Bool, stateFile: PrivilegedJobStateFile?)
    /// 附录 C4：运行时在跑、停机前读不到在跑容器 ⇒ 不停机、放弃本次（root 等不到停机会 stop-timeout，什么都不装）。
    func snapshotUnavailable(nonce: UUID)
}

/// 复原没做完的原因（日志的 allowlist 字段，R4 C）：分得清「被锁挡住」「探不清锁」「起不来」「刻意不拉」「请求没送达」「不归我们」。
/// 只有固定的原始值，没有关联文本——可以放心记成 `.public`。
public enum RestoreHold: String, Sendable, Equatable {
    /// 没有欠账（做完了），或本来就不需要做。
    case none
    /// 锁被别的 root 任务持着（或本次 root 任务可能还没结束）。
    case lockHeld = "lock-held"
    case lockProbeFailed = "lock-probe-failed"
    case startFailed = "start-failed"
    /// raced 且运行时在跑：状态可疑，刻意不自动补拉容器。
    case raced
    /// 请 supervisor reconcile 没在上限内送达。
    case reconcileRequestTimedOut = "reconcile-request-timed-out"
    /// 「起运行时」义务已解除（此前观测到它在跑）：不再替任何人起它。
    case startDischarged = "start-discharged"
    /// 这一刻观测到运行时被别处 / 用户起来了（R4 E-6' 的新鲜探测）：「起运行时」义务就此解除（R5：与上一条分开，日志上分得清）。
    case observedRunning = "observed-running"
}

/// 生产实现：`log stream --predicate 'subsystem == "com.cradleoffilth.supervisor" AND category == "runtime-update"'`。
///
/// `.public` 只给 allowlist 字段：nonce（随机 UUID）、版本号、digest（GitHub 公开的值）、结果名、布尔、计数、退出码。
/// 覆盖率豁免的薄壳（同 `OSLogSupervisorLog`）——它能藏的 P1 只有「把不可信文本记成 `.public`」，由源码扫描守。
public struct OSLogRuntimeUpdateLog: RuntimeUpdateLog {

    private let log: Logger

    public init(subsystem: String = SupervisorLogging.subsystem) {
        self.log = Logger(subsystem: subsystem, category: "runtime-update")
    }

    public func jobStarted(nonce: UUID, target: RuntimeVersion, from: RuntimeVersion, digest: SHA256Digest) {
        log.notice("job started nonce=\(nonce.uuidString, privacy: .public) target=\(target.description, privacy: .public) from=\(from.description, privacy: .public) sha256=\(digest.hex, privacy: .public)")
    }

    public func jobReady(nonce: UUID, runtimeWasRunning: Bool, stopIssued: Bool, runningContainers: Int) {
        log.notice("job ready nonce=\(nonce.uuidString, privacy: .public) runtimeWasRunning=\(runtimeWasRunning, privacy: .public) stopIssued=\(stopIssued, privacy: .public) runningContainers=\(runningContainers, privacy: .public)")
    }

    public func jobFinished(nonce: UUID, outcome: PrivilegedJobOutcome) {
        log.notice("job finished nonce=\(nonce.uuidString, privacy: .public) outcome=\(Self.describe(outcome), privacy: .public) detail=\(Self.privateDetail(outcome), privacy: .private)")
    }

    public func restored(nonce: UUID, leftStopped: Bool, hold: RestoreHold, startOutcome: CommandOutcome?, unrestoredContainers: Int) {
        let level: OSLogType = leftStopped ? .error : .default
        log.log(level: level, "restore nonce=\(nonce.uuidString, privacy: .public) leftStopped=\(leftStopped, privacy: .public) hold=\(hold.rawValue, privacy: .public) start=\(Self.describe(startOutcome), privacy: .public) unrestored=\(unrestoredContainers, privacy: .public) detail=\(Self.privateDetail(startOutcome), privacy: .private)")
    }

    public func snapshotUnavailable(nonce: UUID) {
        log.error("snapshot unavailable nonce=\(nonce.uuidString, privacy: .public): runtime not stopped, update abandoned")
    }

    public func recovering(nonce: UUID, stopIssued: Bool, stateFile: PrivilegedJobStateFile?) {
        log.notice("recovering nonce=\(nonce.uuidString, privacy: .public) stopIssued=\(stopIssued, privacy: .public) stateFile=\(Self.describe(stateFile), privacy: .public)")
    }

    // MARK: - allowlist 渲染（只吐结果名 / 数字，绝不吐外部文本）

    static func describe(_ outcome: PrivilegedJobOutcome) -> String {
        switch outcome {
        case .finished(let result, let blockers, let details):
            "\(result.rawValue)(blockers=\(blockers.count),details=\(details.count))"
        case .cancelled:
            "cancelled"
        case .unknown:
            "unknown"
        }
    }

    static func describe(_ outcome: CommandOutcome?) -> String {
        switch outcome {
        case nil: "not-attempted"
        case .succeeded: "succeeded"
        case .failed(let exitCode, _): "failed(\(exitCode))"
        case .timedOut: "timedOut"
        case .notInstalled: "notInstalled"
        }
    }

    static func describe(_ stateFile: PrivilegedJobStateFile?) -> String {
        switch stateFile {
        case nil: "missing"
        case .ready: "ready"
        case .done(let result): "done(\(result?.rawValue ?? "?"))"
        }
    }

    /// 不可信文本（阻塞路径、installer 细节、osascript stderr）。★ 调用点只准 `.private`——源码扫描守。
    static func privateDetail(_ outcome: PrivilegedJobOutcome) -> String {
        switch outcome {
        case .finished(_, let blockers, let details): (blockers + details).joined(separator: ", ")
        case .cancelled: ""
        case .unknown(let text): text
        }
    }

    static func privateDetail(_ outcome: CommandOutcome?) -> String {
        if case .failed(_, let detail) = outcome { return detail }
        return ""
    }
}
