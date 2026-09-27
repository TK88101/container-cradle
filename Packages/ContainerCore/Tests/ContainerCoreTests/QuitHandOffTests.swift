import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// 退出前交接的总预算（R4 F）。挂死一律用**不响应取消**的 continuation——`Task.sleep` 响应取消，
/// 拿它当挂死会让一个没有上限的实现变绿（`XPCTimeoutTests` 的同一条教训）。
@Suite("QuitHandOff：白名单写入链 + supervisor 交接共用一个总预算")
struct QuitHandOffTests {

    @Test("写入链挂死 → 预算内返回 writesTimedOut，不做 settle")
    func hangingWritesAreBounded() async {
        let settles = Mutex(0)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await QuitHandOff.run(
            budget: .milliseconds(100),
            awaitWrites: { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } },
            settle: { _ in settles.withLock { $0 += 1 }; return true }
        )
        #expect(outcome == .writesTimedOut)
        #expect(settles.withLock { $0 } == 0)
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test("写入链排空、settle 没按时交接完 → settleTimedOut")
    func settleTimeoutIsReported() async {
        let outcome = await QuitHandOff.run(budget: .seconds(5), awaitWrites: {}, settle: { _ in false })
        #expect(outcome == .settleTimedOut)
    }

    /// R5 P2-5：原来的断言 `<= 预算` 对「settle 拿到整份预算」也成立——共用一个总预算这件事没人守。
    @Test("写入链耗掉的时间从 settle 的预算里扣掉（两段共用一个总预算）")
    func settleGetsOnlyWhatIsLeft() async {
        let granted = Mutex<Duration?>(nil)
        let outcome = await QuitHandOff.run(
            budget: .seconds(2),
            awaitWrites: { try? await Task.sleep(for: .milliseconds(300)) },
            settle: { remaining in granted.withLock { $0 = remaining }; return true }
        )
        #expect(outcome == .completed)
        let remaining = granted.withLock { $0 }
        #expect(remaining.map { $0 <= .milliseconds(1_750) } == true, "\(String(describing: remaining))")
    }

    @Test("都按时 → completed；写入链先于 settle，settle 拿到的是剩余预算")
    func writesPrecedeSettleWithinOneBudget() async {
        let events = Mutex<[String]>([])
        let granted = Mutex<Duration?>(nil)
        let outcome = await QuitHandOff.run(
            budget: .seconds(5),
            awaitWrites: { events.withLock { $0.append("writes") } },
            settle: { remaining in
                events.withLock { $0.append("settle") }
                granted.withLock { $0 = remaining }
                return true
            }
        )
        #expect(outcome == .completed)
        #expect(events.withLock { $0 } == ["writes", "settle"])
        let remaining = granted.withLock { $0 }
        #expect(remaining.map { $0 > .zero && $0 <= .seconds(5) } == true)
    }
}
