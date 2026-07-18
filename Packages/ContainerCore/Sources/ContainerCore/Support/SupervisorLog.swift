/// **supervisor 每一次决策的观测出口。** Day 8 的存在理由。
///
/// Day 7 的 M3 红了的时候，没有任何办法知道 supervisor 为什么失败——App 里一行日志都没有，
/// 只能靠截图看菜单栏那行字、靠临时写一个真机测试去打一次 `start()`。
/// 一个无人值守自动干活的常驻进程，**不可观测就等于不可信**：它悄悄熔断的样子和一切正常一模一样。
///
/// ## 为什么是注入式 protocol，不是散落的 `Logger()` 调用
///
/// 两条理由，都是 D2（密钥纪律）逼出来的：
///
/// 1. **可测**：直接在 `Supervisor.handle` 里 `Logger().info(...)`，测试就断言不了「该记的记了」。
///    注入一个 spy，「运行时换代时有没有记下这次转移」就变成一个对调用的断言。
/// 2. **收敛泄漏面**：每一个散落的 `Logger().info("\(x)")` 都可能不小心插进 `reveal()` 的结果
///    （裸 `String`，脱敏不再跟着它走）。把日志收敛到这一个 protocol，明文进不进日志就变成
///    **一个点**，能被单测 + 源码扫描同时守。（此处刻意不写成带点的调用形式，免得被边界扫描器误报。）
///
/// ## ★ 参数用类型杜绝明文（与 `SecretString` 同构）
///
/// 下面每个方法的参数都是 **domain 枚举 / 值类型**，**没有一个能塞进 `SecretString` 或裸明文 `String`**。
/// 唯一带上游文本的入口是 `containerStartFailed`，它收的是 `RuntimeError`（一个 typed enum，
/// 不是裸 `String`）——实现里负责把它的 `reason`/`path` 当**不可信文本**处理（`OSLogSupervisorLog`
/// 里走 `.private`，绝不进 `.public` 位）。于是「不小心把明文记进日志」在这个面上**写不出来**，
/// 不靠 code review 拦（D2 的一贯手法）。
///
/// ## ★ 实现纪律（P1-4，codex review 定案）
///
/// `Supervisor.handle` 全程同步、无重入窗口——这是「actor 没有重入窗口」的**全部依据**
/// （见 `Supervisor` 类型文档）。因此本 protocol 的所有方法**必须**：
/// - **非 `async`、非 `throws`**：绝不在 `handle` 的同步路径里引入挂起点。
/// - **fire-and-forget**：`os.Logger` 本就同步非阻塞。实现**绝不能回调 supervisor**、
///   **绝不能阻塞等待外部队列 / 锁竞争**——那会在同步路径里制造延迟，甚至重入诱因。
/// - spy 实现只在锁下 append，不触发任何回调。
public protocol SupervisorLog: Sendable {

    /// 状态转移。只在状态真的变了时记（稳态每 2 秒的同代 probe 不动作、不记）。
    func transition(from: SupervisorState, to: SupervisorState)

    /// 用户手动按了「立即启动受管容器」。**区分自动边沿触发与人工兜底**——
    /// 两者在 `handle` 里都会走到 `.reconciling`，日志时间线上得能分辨是谁发起的。
    func userForcedReconcile()

    /// 为这一代下达了 reconcile（`.startReconcile` effect）。
    func reconcileStarted(generation: RuntimeGeneration)

    /// 一次 reconcile 有了结局。**带 generation**：迟到 / 换代作废的结局也会记，
    /// 靠 generation 在时间线上定位它属于哪一代（最终状态只以 reducer 采纳的为准，见 P1-5）。
    func reconcileOutcome(_ outcome: ReconcileOutcome, generation: RuntimeGeneration)

    /// reducer 要求发出的一条通知（熔断 / 放弃 / 失败 / 成功 / 手动不可用）。
    func notice(_ notice: SupervisorNotice)

    /// **单个容器 start 失败的诊断细节。** 唯一带上游文本的入口。
    ///
    /// 记在 engine 的 catch 里（`error: RuntimeError` 在手），这是 Day 7「不知道为什么失败」的正解落点。
    /// - Parameter generation: 这次失败属于哪一代（P1-5：可能是已被作废的旧世代，日志据此定位）。
    /// - Parameter error: **实现必须把它的 `reason`/`path` 当不可信文本**（`.private`），
    ///   只有 case 身份与分类可以公开。
    func containerStartFailed(id: ContainerID, generation: RuntimeGeneration, error: RuntimeError)
}

/// 默认实现：什么都不记。**生产以外的所有构造点用它**（测试注 spy，`AppModel` 注 `OSLogSupervisorLog`）。
///
/// 给 `Supervisor` / `WhitelistReconcileEngine` 的 `log` 参数一个默认值，于是加日志的爆炸半径为零：
/// 已有的每一个构造点一个字都不用改。
public struct NullSupervisorLog: SupervisorLog {

    public init() {}

    public func transition(from: SupervisorState, to: SupervisorState) {}
    public func userForcedReconcile() {}
    public func reconcileStarted(generation: RuntimeGeneration) {}
    public func reconcileOutcome(_ outcome: ReconcileOutcome, generation: RuntimeGeneration) {}
    public func notice(_ notice: SupervisorNotice) {}
    public func containerStartFailed(id: ContainerID, generation: RuntimeGeneration, error: RuntimeError) {}
}

/// supervisor 这条线的统一日志身份。**一个常量，两处用**（`OSLogSupervisorLog` 与 app 的
/// `SupervisorNotifier`）——各写各的字面量会在改其中一处时悄悄分裂成两条 `log stream` predicate。
public enum SupervisorLogging {
    public static let subsystem = "com.cradleoffilth.supervisor"
}
