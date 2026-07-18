import Foundation
import Testing

@testable import ContainerCore

/// 真实时钟。**它不是「不可测」的，只是容易被当成不可测而白拿 0% 覆盖**——
/// 而它有两条真会出错的分支：过期的 deadline，和被取消的睡眠。
///
/// 睡眠时长一律取毫秒级，测试不会因此变慢。
@Suite("SystemSupervisorClock")
struct SystemSupervisorClockTests {

    private let clock = SystemSupervisorClock()

    @Test("now 返回当前时刻")
    func nowIsNow() async {
        #expect(abs(await clock.now().timeIntervalSinceNow) < 1)
    }

    /// 「到点或已过点都算到」——tick 因线程调度晚到几毫秒是常态。
    /// 这里若真睡下去，退避到期后 supervisor 会白白多等一整轮。
    @Test("deadline 已经过了 → 立刻返回，不睡")
    func pastDeadlineReturnsImmediately() async {
        let start = Date()

        await clock.sleep(until: Date(timeIntervalSinceNow: -10))

        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test("睡到未来的 deadline → 真的睡了")
    func sleepsUntilDeadline() async {
        let start = Date()

        await clock.sleep(until: Date(timeIntervalSinceNow: 0.05))

        #expect(Date().timeIntervalSince(start) >= 0.04)
    }

    /// **取消必须能把它叫醒。** 叫不醒 = `Supervisor.stop()` 之后那条 tick task
    /// 会一直挂在那儿——菜单栏 App 是常驻进程，这种泄漏会一直累积。
    @Test("被取消 → 立刻醒（且不把 CancellationError 抛给调用方）")
    func cancellationWakesTheSleeper() async {
        let start = Date()

        let task = Task { await clock.sleep(until: Date(timeIntervalSinceNow: 60)) }
        task.cancel()
        await task.value

        #expect(Date().timeIntervalSince(start) < 1)
    }
}
