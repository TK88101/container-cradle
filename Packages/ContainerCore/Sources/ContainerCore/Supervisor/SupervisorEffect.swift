import Foundation

/// reducer **描述**出来的副作用。它自己一个都不执行——执行是 `Supervisor` actor（Day 5）的事。
///
/// 这层间接不是形式主义：只要副作用是被「返回」的而不是被「做」的，
/// 「运行时换代时有没有下达 reconcile」就变成一个**对返回值的断言**，
/// 不需要起容器、不需要等异步、不需要假时钟以外的任何东西。
/// 状态机 100% 可单测，正是从这一条来的。
public enum SupervisorEffect: Equatable, Sendable {

    /// 为这一代拉起白名单容器。
    case startReconcile(generation: RuntimeGeneration)

    /// 作废在途的那次 reconcile。
    ///
    /// 它和 `startReconcile` 成对出现在「换代」路径上：为 g1 拉到一半，运行时换成了 g2——
    /// 在途那次拉的是**上一代的容器**，继续拉没有意义（甚至会对着已经消失的运行时报错）。
    ///
    /// 语义是**作废**，不保证**中止**：跟 `ContainerListStore.refresh()` 里的 `Task.cancel()` 一样，
    /// 底层调用没有取消语义，旧 reconcile 可能照跑完——但它的 `reconcileFinished(g1)` 回来时
    /// 会被 stale 判定拦下，结果不落地。
    case cancelReconcile(generation: RuntimeGeneration)

    /// 请在 `at` 这个时刻给我一个 `tick`。用来把 `.cooldown` 叫醒。
    ///
    /// **必须由 reducer 显式要求**，不能指望「反正轮询会一直发 probe」：
    /// 稳态下 probe 全是同一代的 running，reducer 对它们一律不动作
    /// （见 `.cooldown` + `probed(running(同一代))` 那一格）——没有这个 effect，
    /// 退避到期后就没有任何东西会把它叫醒，容器永远停在那儿。
    case scheduleTick(at: Date)

    /// 通知 / 记录。
    case notify(SupervisorNotice)

    /// 这条 Effect 携带的通知（没有就是 `nil`）。
    /// `Supervisor.handle` 用它把一轮里的通知收进同一份 `SupervisorSnapshot`。
    var notice: SupervisorNotice? {
        guard case .notify(let notice) = self else { return nil }

        return notice
    }
}

/// 值得让用户知道的事。
///
/// **刻意只携带令牌与计数，不携带容器 env、不携带任何 `SecretString`**（D2）：
/// notice 会走到通知中心、日志、崩溃报告里——那正是密钥最不该出现的三个地方。
/// 需要展示容器名时由 UI 层拿 ID 去查，而不是让 notice 顺路把整个 `Container` 捎过去。
public enum SupervisorNotice: Equatable, Sendable {

    /// 这一代的容器已经拉起来了。
    case reconcileSucceeded(generation: RuntimeGeneration)

    /// 这一代拉失败了，将在 `retryAt` 重试。
    ///
    /// - Parameter kind: 失败的性质。UI 靠它决定说什么话——
    ///   `.environmentNotReady` 该说「等待挂载源就绪（外置盘还没挂上？）」，
    ///   而不是笼统地报「启动失败」。前者让用户知道该去插上硬盘，后者让他去翻日志。
    case reconcileFailed(
        generation: RuntimeGeneration,
        kind: FailureKind,
        attempt: Int,
        retryAt: Date
    )

    /// **熔断了。** 这一代在窗口内失败了 `failures` 次，已经停止一切自动重试。
    ///
    /// 这条通知是**必须**的，不是可选的：熔断意味着 supervisor 从此不再干活，
    /// 而它不干活的时候看起来和「一切正常」一模一样。不告诉用户，
    /// 他会以为容器还被守着，直到某天发现它已经停了几个小时。
    case circuitOpened(generation: RuntimeGeneration, failures: Int)

    /// **放弃了。** 遇到重试也没用的失败（容器不存在——白名单 ID 拼错、或者容器被删了）。
    ///
    /// 与 `circuitOpened` 分开：那是「它一直崩」，这是「它压根不在」。
    /// 两者要用户做的事完全不同（前者去查容器为什么崩，后者去改白名单），
    /// 混成一条通知等于让用户自己去猜。
    case reconcileAbandoned(generation: RuntimeGeneration)

    /// 用户手动要求 reconcile，但当前没有运行时可拉（`.unknown` / `.runtimeDown`）。
    ///
    /// **必须告诉用户「没做」**，不能静默吞掉：他刚按了一个按钮，
    /// 什么都不发生等于让他怀疑按钮坏了，然后去点第二次、第三次。
    case forcedReconcileUnavailable
}
