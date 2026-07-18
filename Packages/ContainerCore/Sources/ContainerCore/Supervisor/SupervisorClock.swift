import Foundation

/// supervisor 的时间来源。**注入它不是洁癖，是因为不注入就没法测。**
///
/// 退避到 5 分钟上限、熔断窗口 10 分钟——这些分支若靠真实时间去撞，一条测试要跑十分钟，
/// 于是没人会写，于是它们没有测试。`ManualClock` 让「等 10 分钟」变成一行 `advance(by:)`。
///
/// reducer 本身不需要时钟（时间由事件携带）。这里的时钟只服务 actor：
/// **谁来回答「现在几点」，以及谁来把 tick 睡醒。**
public protocol SupervisorClock: Sendable {

    func now() async -> Date

    /// 睡到 `deadline`。**必须响应取消**——`Supervisor.stop()` 会 cancel 正在睡的 task，
    /// 睡不醒的话进程退不干净（菜单栏 App 常驻，这种泄漏会一直累积）。
    func sleep(until deadline: Date) async
}

/// 真实时钟。
public struct SystemSupervisorClock: SupervisorClock {

    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async {
        let interval = deadline.timeIntervalSinceNow

        // 已经过点了就别睡。「到点或已过点都算到」——tick 因为线程调度晚到几毫秒是常态，
        // 用严格大于会让它白白多睡一整轮（reducer 的 `tick` 那一格记的是同一条）。
        guard interval > 0 else { return }

        // 取消时 `Task.sleep` 抛 `CancellationError`。**吞掉它**：调用方恢复后自己检查
        // `Task.isCancelled`（那才是它该做的判断），而不是让「被取消」伪装成一个需要处理的错误。
        try? await Task.sleep(for: .seconds(interval))
    }
}
