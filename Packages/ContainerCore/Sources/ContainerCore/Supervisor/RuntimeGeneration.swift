/// **D3 的令牌。** apiserver 的这一次生命——`(pid, startTime)`。
///
/// ## 为什么不能只看 down → running 的边沿
///
/// 轮询有间隔（秒级）。运行时**快速重启**（`container system stop && container system start`，
/// 或 launchd 崩溃后立刻重拉）完全可能在两次轮询之间跑完：上一次探测看到 running，
/// 下一次探测还是看到 running——纯边沿检测**什么都没看见**，容器却已经全没了。
/// supervisor 于是静默失效，而且**永远不会自愈**（它在等一个不会再来的 down→running 边沿）。
///
/// 令牌把「运行时换代了」变成一个**可观测的值变化**，而不是一个可能被采样漏掉的**瞬时事件**。
/// 两次探测都是 running 但 `generation` 不同 → 中间必然死过一次 → 该 reconcile。
///
/// ## pid 单独不够
///
/// pid 会**复用**。apiserver 挂掉后系统可以把同一个 pid 分给新进程（甚至新的 apiserver），
/// 只比 pid 会漏判「换代了但 pid 恰好相同」。`startTime` 让令牌在实践中唯一：
/// 同一个 pid 在同一微秒启动两次是不可能的。
///
/// ## Day 3 只有值类型
///
/// 真正去 libproc 读 `proc_bsdinfo` 的是 Day 5 的 `RuntimeProber`。reducer 只需要
/// 「这两个令牌相不相等」——它不关心令牌从哪来，这正是它能被纯单测的原因。
public struct RuntimeGeneration: Hashable, Sendable {

    /// apiserver 的进程号。
    public let pid: Int32

    /// 进程启动时刻（`proc_bsdinfo` 的 `pbi_start_tvsec`/`pbi_start_tvusec` 合成的微秒数）。
    ///
    /// 这里只要求**同一进程的两次读取必然相等、不同生命的两次读取必然不等**。
    /// 具体单位与纪元由 `RuntimeProber`（Day 5）决定；reducer 只做相等性判断，不做算术。
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}
