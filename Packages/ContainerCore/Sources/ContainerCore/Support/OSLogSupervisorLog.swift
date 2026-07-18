import os

/// `SupervisorLog` 的生产实现：写进统一日志系统（`os.Logger`）。
///
/// 验收：`log stream --predicate 'subsystem == "com.cradleoffilth.supervisor"'` 期间跑
/// `container system stop && container system start`，能看到 down → running → reconcileStarted
/// → reconcileOutcome(.success) 的完整时间线。
///
/// ## ★ 这是覆盖率豁免层，也是 D2 的最后一道薄墙
///
/// 它跟 `LibprocProcessTable` 一样是「拿不到确定性输入」的薄壳——真正的 os.Logger 后端没法在单测里
/// 断言。但「被豁免的那一层最容易藏 P1」（`LibprocProcessTable` 的 proc_listallpids 单位就藏过一个）。
/// 这里能藏的 P1 只有一种：**把不可信文本写成 `.public`**。所以：
///
/// - **公开的只有 allowlist 的安全字段**：事件名字面量、`generation` 的 pid/startTime、
///   `FailureKind` case 名、计数、时间戳。全是数字 / 布尔 / 枚举名，**不含任何上游字符串**。
///   （codex P1-1：不 `"\(state, privacy: .public)"` 全量插值——将来给 state 加个带明文的关联值就漏了。）
/// - **`RuntimeError` 的 `reason`/`path` 一律 `.private`**（codex P1-3：path 可能含用户名 / 项目名）。
///   分类（`publicKind`）可以公开，原始文本只走 `privateDetail` → `.private`。
///
/// 这条纪律由 `BoundaryScanner` 的专项规则钉死（本文件里 `detail` 不许以 `.public` 出现）。
public struct OSLogSupervisorLog: SupervisorLog {

    private let stateLog: Logger
    private let reconcileLog: Logger

    public init(subsystem: String = SupervisorLogging.subsystem) {
        self.stateLog = Logger(subsystem: subsystem, category: "state")
        self.reconcileLog = Logger(subsystem: subsystem, category: "reconcile")
    }

    public func transition(from: SupervisorState, to: SupervisorState) {
        stateLog.info("transition \(Self.describe(from), privacy: .public) -> \(Self.describe(to), privacy: .public)")
    }

    public func userForcedReconcile() {
        stateLog.info("user forced reconcile")
    }

    public func reconcileStarted(generation: RuntimeGeneration) {
        reconcileLog.info("reconcile started gen=\(generation.pid, privacy: .public)/\(generation.startTime, privacy: .public)")
    }

    public func reconcileOutcome(_ outcome: ReconcileOutcome, generation: RuntimeGeneration) {
        reconcileLog.info("reconcile outcome=\(Self.describe(outcome), privacy: .public) gen=\(generation.pid, privacy: .public)/\(generation.startTime, privacy: .public)")
    }

    public func notice(_ notice: SupervisorNotice) {
        stateLog.notice("notice \(Self.describe(notice), privacy: .public)")
    }

    public func containerStartFailed(id: ContainerID, generation: RuntimeGeneration, error: RuntimeError) {
        // id.rawValue 公开：容器名是用户自选、进 git 的白名单条目，不是密钥。
        // ★ error 的原始文本（reason/path）走 detail 且**只准 .private**——见类型文档。
        reconcileLog.error(
            "container start failed id=\(id.rawValue, privacy: .public) gen=\(generation.pid, privacy: .public)/\(generation.startTime, privacy: .public) kind=\(Self.publicKind(error), privacy: .public) detail=\(Self.privateDetail(error), privacy: .private)"
        )
    }

    // MARK: - allowlist 渲染（只吐安全字段，绝不吐上游文本）

    private static func describe(_ state: SupervisorState) -> String {
        switch state {
        case .unknown:
            "unknown"
        case .runtimeDown:
            "runtimeDown"
        case .runtimeUp(let g, let baseline):
            "runtimeUp(gen=\(gen(g)),baseline=\(baseline))"
        case .reconciling(let g, let failures):
            "reconciling(gen=\(gen(g)),attempts=\(failures?.attempts ?? 0))"
        case .cooldown(let g, let until, let failures):
            "cooldown(gen=\(gen(g)),attempts=\(failures.attempts),until=\(until.timeIntervalSince1970))"
        case .circuitOpen(let g, let since):
            "circuitOpen(gen=\(gen(g)),since=\(since.timeIntervalSince1970))"
        }
    }

    private static func describe(_ outcome: ReconcileOutcome) -> String {
        switch outcome {
        case .success:
            "success"
        case .failure(let kind):
            "failure(\(describe(kind)))"
        }
    }

    private static func describe(_ notice: SupervisorNotice) -> String {
        switch notice {
        case .reconcileSucceeded(let g):
            "reconcileSucceeded(gen=\(gen(g)))"
        case .reconcileFailed(let g, let kind, let attempt, let retryAt):
            "reconcileFailed(gen=\(gen(g)),kind=\(describe(kind)),attempt=\(attempt),retryAt=\(retryAt.timeIntervalSince1970))"
        case .circuitOpened(let g, let failures):
            "circuitOpened(gen=\(gen(g)),failures=\(failures))"
        case .reconcileAbandoned(let g):
            "reconcileAbandoned(gen=\(gen(g)))"
        case .forcedReconcileUnavailable:
            "forcedReconcileUnavailable"
        }
    }

    private static func describe(_ kind: FailureKind) -> String {
        switch kind {
        case .environmentNotReady: "environmentNotReady"
        case .transient: "transient"
        case .permanent: "permanent"
        }
    }

    private static func gen(_ g: RuntimeGeneration) -> String {
        "\(g.pid)/\(g.startTime)"
    }

    /// `RuntimeError` 的**公开身份**：只有 case 名，绝无上游文本。
    private static func publicKind(_ error: RuntimeError) -> String {
        switch error {
        case .runtimeUnavailable: "runtimeUnavailable"
        case .containerNotFound: "containerNotFound"
        case .mountSourceUnavailable: "mountSourceUnavailable"
        case .operationFailed: "operationFailed"
        }
    }

    /// `RuntimeError` 的**不可信原始文本**。★ 调用点必须 `.private`——由 `BoundaryScanner` 钉死。
    private static func privateDetail(_ error: RuntimeError) -> String {
        switch error {
        case .runtimeUnavailable:
            ""
        case .containerNotFound(let id):
            id.rawValue
        case .mountSourceUnavailable(let path):
            path
        case .operationFailed(let reason):
            reason
        }
    }
}
