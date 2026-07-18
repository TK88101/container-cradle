import Foundation
import Testing

@testable import ContainerCore

/// 退避**曲线**本身。跟状态**转移**是两个独立命题——转移测试注入 `FixedBackoff`，
/// 一个数字都不从这里借；这里也不构造任何状态转移。
@Suite("ExponentialBackoff（退避曲线）")
struct ExponentialBackoffTests {

    let backoff = ExponentialBackoff()

    @Test(
        "1s 起步，每次翻倍",
        arguments: [(1, 1.0), (2, 2.0), (3, 4.0), (4, 8.0), (5, 16.0), (6, 32.0)]
    )
    func doublesEachAttempt(attempt: Int, expected: TimeInterval) {
        #expect(backoff.delay(forAttempt: attempt) == expected)
    }

    @Test("封顶 5 分钟，不再往上翻")
    func capsAtFiveMinutes() {
        // 2^8 = 256s 还在顶下，2^9 = 512s 越顶。
        #expect(backoff.delay(forAttempt: 9) == 256)
        #expect(backoff.delay(forAttempt: 10) == 300)

        // ★ 封顶之后必须**稳定**在 300，不能溢出成负数或 inf。
        // R13 的场景（外置盘迟迟不挂上）会让 environmentNotReady 一直重试下去——
        // attempt 会涨到很大。这里一溢出，supervisor 要么突然疯狂重试，要么彻底不再重试。
        #expect(backoff.delay(forAttempt: 60) == 300)
        #expect(backoff.delay(forAttempt: 1000) == 300)
        #expect(backoff.delay(forAttempt: Int.max) == 300)
    }

    @Test("attempt 小于 1 是调用方的 bug，但也必须给出安全值而不是崩")
    func clampsBelowOne() {
        #expect(backoff.delay(forAttempt: 0) == 1)
        #expect(backoff.delay(forAttempt: -5) == 1)

        // ★ `Int.min`：若实现写成 `attempt - 1` 再夹取，这一行会**整数下溢直接 trap**，
        // 上面那句「不许崩」就成了空话——而且是在最难复现的路径上。
        // （codex/altitude review 抓到的：先夹再减，不是先减再夹。）
        #expect(backoff.delay(forAttempt: Int.min) == 1)
    }

    @Test("单调不减")
    func isMonotonic() {
        let delays = (1...20).map { backoff.delay(forAttempt: $0) }

        for (earlier, later) in zip(delays, delays.dropFirst()) {
            #expect(later >= earlier)
        }
    }

    @Test("首次延迟与上限可配")
    func isConfigurable() {
        let fast = ExponentialBackoff(first: 0.5, cap: 4)

        #expect(fast.delay(forAttempt: 1) == 0.5)
        #expect(fast.delay(forAttempt: 2) == 1)
        #expect(fast.delay(forAttempt: 3) == 2)
        #expect(fast.delay(forAttempt: 4) == 4)
        #expect(fast.delay(forAttempt: 5) == 4)
    }
}
