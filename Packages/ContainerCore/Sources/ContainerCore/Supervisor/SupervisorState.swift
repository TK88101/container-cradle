import Foundation

/// supervisor 的全部状态。**这台状态机就是本 App 存在的理由**
/// （apple/container 没有 restart policy——运行时回来，容器不会自己回来）。
///
/// ## 为什么 generation 挂在状态上，而不是存成一个旁路变量
///
/// 「当前是哪一代」和「当前处于什么阶段」是**同一个事实的两面**：
/// `.runtimeDown` 时没有代（运行时都不在了，谈何代号），`.reconciling` 时必然有代
/// （正在为**某一代**拉容器）。拆成两个字段就能表达 `.runtimeDown + generation` 这种
/// 无意义组合，然后每个消费者都得写分支去猜它是什么意思。
///
/// 这跟 `ContainerListStore.LoadState` 用三态 enum 而不是「数组 + error + isLoading」
/// 是同一条理由：**让非法状态无法表示**。
public enum SupervisorState: Equatable, Sendable {

    /// 还没探测过。app 刚启动的第一个瞬间。
    ///
    /// 它和 `.runtimeDown` **必须分开**：从 `.unknown` 看到 running 是「冷启动时它本来就在跑」
    /// → **不 reconcile**（用户可能 5 分钟前刚手动停了容器正在调试，一启动就拉起是在和他对着干）；
    /// 从 `.runtimeDown` 看到 running 是「它刚刚回来」→ **必须 reconcile**。
    /// 合并这两个状态，二选一必然做错：要么冷启动乱拉，要么核心场景不拉。
    case unknown

    /// 探测确认 apiserver 不在。
    case runtimeDown

    /// apiserver 在跑，且当前这一代已经处理完了。
    ///
    /// - Parameter baseline: `true` 表示这一代是**冷启动时就已经在跑**的，我们没有为它 reconcile
    ///   （见 `.unknown` 的说明）。`false` 表示这一代是我们 reconcile 过的。
    ///   这个 flag 是给 UI 用的：baseline 且白名单里有容器停着 → 菜单栏非侵入提示
    ///   「N 个受管容器未运行 · 立即启动」。**告知，不代劳。**
    case runtimeUp(generation: RuntimeGeneration, baseline: Bool)

    /// 正在为 `generation` 这一代拉起白名单容器。
    ///
    /// 这是个**在途异步操作**的状态：reconcile 要对每个白名单容器跑一遍 bootstrap 序列
    /// （PLAN.md「reconcile 要执行的真实序列」），耗时可达数秒。这期间轮询**不会停**，
    /// 所以 `.reconciling` 收到 `probed` 是常态，不是边角料——转移表必须覆盖。
    ///
    /// - Parameter failures: 进入这一轮**之前**已经累积的失败串（`nil` = 一次都还没失败过）。
    ///
    ///   不带它，退避就是坏的：`cooldown → tick → reconciling → 又失败` 时计数已经丢了，
    ///   于是新的 cooldown 又是第 1 次——**指数退避永远停在第一档**，
    ///   熔断也永远不会触发（它在等一个到不了的阈值），crashloop 就此无限打铁。
    ///   失败计数必须活在**状态**里，不能活在「上一格的记忆」里。
    case reconciling(generation: RuntimeGeneration, failures: FailureStreak?)

    /// 上一次 reconcile 失败了，退避到 `until` 再重试。
    ///
    /// - Parameter failures: 累积的失败串（次数 + 窗口起点）。退避曲线看次数，熔断看「窗口内的次数」。
    ///   运行时换代或挂掉时**整串丢弃**——那是全新局面，不该继承旧的失败债。
    case cooldown(generation: RuntimeGeneration, until: Date, failures: FailureStreak)

    /// **熔断。** 这一代反复失败到了阈值，已经停止一切自动重试。
    ///
    /// 唯一的出口是 `userForcedReconcile`——**必须要求人来按一下**。
    /// 「绝不静默无限重试」是这个状态存在的全部理由：一个起来就崩的容器，
    /// 让 supervisor 无限拉它，只会把 CPU、日志和用户的注意力一起烧光。
    ///
    /// 但**熔断绝不是终身监禁**：运行时换代或挂掉时它就作废了（见 reducer）——
    /// 上一代的 crashloop 很可能正是运行时自己病了导致的，
    /// 让新一代继承那个熔断，等于 apiserver 一崩就再也不管容器了。
    ///
    /// 熔断也**只对 `.transient` 失败开放**：`.environmentNotReady`（mount 源没就绪）
    /// 永远不会走到这里，否则 R13 的核心场景会在 31 秒后被判死。
    case circuitOpen(generation: RuntimeGeneration, since: Date)
}

// 这里刻意**没有** `var generation: RuntimeGeneration?` 这样的便利属性。
//
// 它看起来很顺手，但唯一的用处是让 `reduce` 写成 `guard let g = state.generation else { … }`——
// 而那会把 `userForcedReconcile` 的**穷尽 switch 换成 guard**，于是丢掉编译期闸门：
// 将来给 `SupervisorState` 加一个 case（Day 4 的 `.circuitOpen` 就是），
// 穷尽 switch 会**编译报错**逼人显式决定它该怎么处理；`guard let` 只会静默走 else 分支，
// 新状态于是被一个既有分支悄悄吞掉。
//
// 这跟 `RuntimeError` 只留两个 case 是同一条理由：**让新形态无法被静默吞掉。**
