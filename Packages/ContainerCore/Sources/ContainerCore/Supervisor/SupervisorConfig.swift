import Foundation

/// reducer 的**不可变环境**。不是状态——它在两次事件之间不变，所以不进 `SupervisorState`
/// （放进状态就要在每一格转移里原样搬运一遍，纯噪音，还给「转移时不小心改了配置」留了门）。
public struct SupervisorConfig: Equatable, Sendable {

    /// 冷启动时若 apiserver 已在跑，要不要顺手 reconcile 一次。**默认关**。
    ///
    /// 关的理由（PLAN.md 已拍板）：
    /// 1. **用户意图不可知**——容器停着，可能是他 5 分钟前手动 `container stop` 的（正在调试）。
    ///    一启动就拉起是在和他对着干。
    /// 2. **误伤成本不对称**——不拉起 = 他多点一下；拉错 = 覆盖他正在进行的操作。
    /// 3. **核心场景不受影响**——真正的核心场景是「Mac 重启 / apiserver 崩了」，
    ///    那时 app 由 `SMAppService` 登录自启，**早于或并行于 apiserver** → 先看到 `.runtimeDown`
    ///    → 再看到 running → **正常走边沿，reconcile 照常发生**。
    ///    baseline 只在「你手动打开 app 而 apiserver 早就在跑」时命中——那恰恰最该保守。
    public let reconcileOnLaunch: Bool

    /// 窗口内失败多少次触发熔断。**至少 1**（见 `init`）。
    public let circuitBreakerThreshold: Int

    /// 熔断的观察窗口。**必须为正**（见 `init`）。
    ///
    /// **只有窗口内的密集失败才算 crashloop**——每小时崩一次的容器，一天也能攒够 5 次，
    /// 但它显然不是 crashloop。没有窗口，前者迟早被误判成后者，
    /// 然后 supervisor 被一件持续一天的小事关掉。
    public let circuitBreakerWindow: TimeInterval

    /// ## 两个数字都被夹进合法区间，不是「相信调用方」
    ///
    /// 这不是防御性编程的洁癖，两个非法值各自会造成一场灾难，而且方向相反：
    ///
    /// - **`threshold <= 0`**：熔断判据是 `breakerCount >= threshold`。
    ///   而 `.environmentNotReady` 的 `breakerCount` 是 **0**——`0 >= 0` 为**真**。
    ///   于是「外置盘还没挂上」的第一次失败就直接熔断，**R13 的硬约束被边界值整个绕开**，
    ///   supervisor 在它唯一该活着的场景里秒死。
    ///   有人把 0 当成「关闭熔断」来填，得到的却是「一失败就永久放弃」。
    ///
    /// - **`window <= 0`**：滑动窗口退化成空集，`breakerCount` 永远追不上阈值，
    ///   **熔断永远不会触发**——真正的 crashloop 被无限放行，安全网名存实亡。
    ///
    /// 这两个洞都不该靠「调用方不会那么填」来堵。夹在这里，非法值就表达不出来。
    public init(
        reconcileOnLaunch: Bool = false,
        circuitBreakerThreshold: Int = 5,
        circuitBreakerWindow: TimeInterval = 600
    ) {
        self.reconcileOnLaunch = reconcileOnLaunch
        self.circuitBreakerThreshold = max(circuitBreakerThreshold, 1)
        self.circuitBreakerWindow = max(circuitBreakerWindow, 1)
    }

    public static let `default` = SupervisorConfig()
}

/// 「第 n 次失败后等多久再试」。
///
/// ## 为什么是 protocol 而不是把公式直接写进 reducer
///
/// 状态**转移**的正确性和退避**曲线**的正确性是两个独立命题。把公式焊进 reducer，
/// 「换代时要清空退避计数」这类转移测试就得跟着 `1s / 2s / 4s` 这些数字走——
/// 改一次退避曲线，一堆跟退避毫无关系的转移测试跟着红。
///
/// 抽出来之后：Day 3 的转移表测试注入 `FixedBackoff`（每次都返回同一个值），
/// 断言里没有一个数字来自退避曲线；Day 4 单独测 `ExponentialBackoff` 的序列本身。
/// 两边都不会因为对方改动而假红。
public protocol BackoffPolicy: Sendable {

    /// 第 `attempt` 次失败（1 起）之后该等多久。
    func delay(forAttempt attempt: Int) -> TimeInterval
}
