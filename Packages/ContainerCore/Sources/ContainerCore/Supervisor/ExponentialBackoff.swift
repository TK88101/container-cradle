import Foundation

/// 指数退避：`1s → 2 → 4 → 8 → … → 300s（5 分钟）封顶`。
///
/// ## 为什么必须封顶，且封顶后必须**稳定**
///
/// R13 的场景里，`.environmentNotReady`（mount 源路径还没挂上）会**一直重试下去**——
/// 外置盘可能十分钟后才就绪，而我们不许熔断它（熔断只留给真正的 crashloop）。
/// 于是 `attempt` 会涨到很大的数。
///
/// `pow(2, attempt)` 在 attempt 大到一定程度会溢出成 `inf`，
/// 用整数移位则会溢出成**负数**——两种都是灾难：前者让 supervisor 再也不重试，
/// 后者让它疯狂重试（负延迟 = 立刻到期）。所以这里在**进入幂运算之前**就先夹住指数。
///
/// ## 没有 jitter
///
/// jitter 是给「一大群客户端同时重试打垮服务端」用的。这里只有**一个** supervisor
/// 对着**本机**的 apiserver，没有惊群可言。加了只会让退避时刻变得不可预测，
/// 测试还得跟着放宽断言——用一个不存在的问题去换一批更弱的测试，不划算。
public struct ExponentialBackoff: BackoffPolicy {

    private let first: TimeInterval
    private let cap: TimeInterval

    /// 越过这个指数，`first * 2^n` 必然已经超过任何合理的 `cap`（2^40 ≈ 1.1e12 秒）。
    /// **先夹指数再算幂**，从根上避免溢出——而不是算完再去检查结果是不是 `inf`。
    private static let maxExponent = 40

    public init(first: TimeInterval = 1, cap: TimeInterval = 300) {
        self.first = first
        self.cap = cap
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        // attempt < 1 是调用方的 bug。给个安全值，不崩——
        // supervisor 半夜因为一个越界的计数崩掉，比多等一秒糟糕得多。
        //
        // ★ **先夹再减**，不是先减再夹：`attempt - 1` 在 `attempt == Int.min` 时整数下溢，
        // Swift 直接 fatal trap。上面那句「不许崩」就成了空话——而且是在最难复现的路径上。
        let clamped = min(max(attempt, 1), Self.maxExponent + 1)

        return min(first * pow(2, TimeInterval(clamped - 1)), cap)
    }
}
