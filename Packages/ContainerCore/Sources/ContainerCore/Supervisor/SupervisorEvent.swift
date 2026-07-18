import Foundation

/// 一次探测的结果。**由 `RuntimeProber`（Day 5）读进程表得出，不由 XPC 错误推断。**
///
/// 诱惑是「XPC 连不上 → 运行时挂了」。不行：XPC 连接失败有一堆别的原因
/// （launchd 还没 on-demand 拉起 apiserver、Mach service 名字对不上、瞬时抖动），
/// 而 supervisor 把它们全当成换代，就会去重启一堆本来好好的容器。
/// **XPC 错误只是提示，进程表才是事实**（`RuntimeError` 里记了同一条）。
public enum ProbeResult: Equatable, Sendable {

    /// apiserver 在跑，这是它这一次生命的令牌。
    case running(RuntimeGeneration)

    /// apiserver 不在。
    case down
}

/// 失败的**性质**。决定 supervisor 是重试、放弃，还是熔断。
///
/// ## 为什么是三档，不是「可重试 / 不可重试」两档
///
/// 熔断阈值是「10 分钟内 5 次」，而退避是 `1→2→4→8→16` 秒——
/// **五次失败只花 31 秒**。R13 的核心场景（Mac 重启后外置盘/网络卷还没挂上）
/// 动辄要几分钟才就绪。若把它归进「可重试」这一档，supervisor 会在 **31 秒后熔断放弃**，
/// 正好死在它唯一该活着的那一刻——本 App 的全部价值当场归零。
///
/// PLAN.md 早就写了正确答案：「退避重试，别熔断；**熔断只留给真正的 crashloop**」。
/// 那就需要一档「重试但不计入熔断」的失败——于是有了 `.environmentNotReady`。
public enum FailureKind: Equatable, Sendable {

    /// **环境还没就绪**，不是容器的错。退避重试，**不计入熔断**（可以一直试下去）。
    ///
    /// 典型：virtiofs mount 的源路径不存在——宿主的外置盘、网络卷在 Mac 重启后
    /// 需要几十秒到几分钟才挂上（PLAN.md R13）。**这正是核心场景的高发情形**，
    /// 也正是它必须永远不被熔断的原因：等下去就一定会成功，放弃则一定失败。
    ///
    /// 退避会涨到 5 分钟上限后稳住，所以「一直试」的成本极低。
    case environmentNotReady

    /// **瞬时故障**，可能是容器自己的问题。退避重试，**计入熔断**。
    ///
    /// 这一档才是熔断要防的东西：容器起来就崩、崩了又被拉起——crashloop 打铁。
    case transient

    /// **重试一万次也没用。** 不重试、不退避、不计入熔断，直接报给用户。
    ///
    /// 典型：`containerNotFound`——白名单里的 ID 拼错了，或者容器被 `container delete` 删了。
    /// 对着一个永远不会出现的容器无限重试，只会把日志刷满，并让真正的问题埋在噪音里。
    case permanent
}

/// 一次 reconcile 的结局。
public enum ReconcileOutcome: Equatable, Sendable {
    case success
    case failure(FailureKind)
}

/// 喂给 reducer 的事件。**每个事件都自带时间**——reducer 是纯函数，它不许自己去问「现在几点」。
///
/// 时间由事件携带（而不是 reducer 调 `Date()`）是这台状态机可测的前提：
/// 测试里 `t0`、`t0 + 30` 都是常量，「退避已到期」「冷却还没到点」这些分支于是**必然**被触发，
/// 而不是靠 sleep 去撞运气。
public enum SupervisorEvent: Equatable, Sendable {

    /// 探测回来了。
    case probed(ProbeResult, at: Date)

    /// 一次 reconcile 结束了。
    ///
    /// **`generation` 不是冗余信息，它是 stale 判定的唯一依据。**
    /// reconcile 是异步的：为 g1 发起的那次跑到一半，运行时可能又换代了，
    /// 状态已经推进到 `.reconciling(g2)`。此时 g1 的结果回来——它描述的是一个**已经不存在的世界**，
    /// 必须丢弃。若不带令牌，reducer 只能盲信「谁最后回来算谁的」，
    /// 于是把状态写成 `.runtimeUp(g1)`，g2 那一代的容器再也没人管了。
    ///
    /// 这正是 `ContainerListStore` 踩过的那个坑（旧刷新覆盖新刷新）在状态机里的同构：
    /// **异步结果回写必须带令牌校验。**
    case reconcileFinished(ReconcileOutcome, generation: RuntimeGeneration, at: Date)

    /// 定时器到点了。用来把 `.cooldown` 叫醒。
    case tick(now: Date)

    /// 用户手动按了「立即启动受管容器」。
    ///
    /// **手动兜底必须存在**：任何自动状态机都会有它没想到的局面，
    /// 那时用户需要一个不讲道理、直接生效的出口。
    case userForcedReconcile(at: Date)
}
