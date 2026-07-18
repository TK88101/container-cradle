import Testing

@testable import ContainerCore

/// `CPUPercentCalculator`：照抄上游数学，**用 `Duration` 钉死单位**（P1-8）。
/// 每条测试都用真实的微秒/秒数字，不写抽象比例——量纲错误只有喂真实数字才会暴露。
@Suite("CPUPercentCalculator：Duration 运算，量纲自洽")
struct CPUPercentCalculatorTests {

    @Test("500,000 微秒 CPU 时间 / 1 秒间隔 → 50%")
    func computesCorrectPercentWithRealUnits() {
        let percent = CPUPercentCalculator.percent(
            previous: 0,
            current: 500_000,
            interval: .seconds(1)
        )

        #expect(percent == 50)
    }

    @Test("1,000,000 微秒 CPU 时间 / 1 秒间隔 → 100%（一个满载核）")
    func fullyLoadedCoreIsOneHundredPercent() {
        let percent = CPUPercentCalculator.percent(
            previous: 0,
            current: 1_000_000,
            interval: .seconds(1)
        )

        #expect(percent == 100)
    }

    @Test("2,000,000 微秒 CPU 时间 / 1 秒间隔 → 200%（两个满载核）")
    func canExceedOneHundredPercentAcrossMultipleCores() {
        let percent = CPUPercentCalculator.percent(
            previous: 0,
            current: 2_000_000,
            interval: .seconds(1)
        )

        #expect(percent == 200)
    }

    @Test("previous 缺失 → nil")
    func missingPreviousIsNil() {
        #expect(CPUPercentCalculator.percent(previous: nil, current: 100, interval: .seconds(1)) == nil)
    }

    @Test("current 缺失 → nil")
    func missingCurrentIsNil() {
        #expect(CPUPercentCalculator.percent(previous: 100, current: nil, interval: .seconds(1)) == nil)
    }

    /// ★ P2-3：计数器 reset（容器重启过）→ 占位 `nil`，**不是** 0%。
    @Test("current < previous（计数器 reset）→ nil，不是 0%")
    func counterResetYieldsNilNotZero() {
        let percent = CPUPercentCalculator.percent(previous: 1_000_000, current: 100, interval: .seconds(1))
        #expect(percent == nil)
    }

    /// ★ P2-3：真的空转 → 0%，与 reset 的 `nil` 必须能区分开。
    @Test("current == previous（真的空转）→ 0%")
    func trueIdleIsZeroPercent() {
        let percent = CPUPercentCalculator.percent(previous: 500_000, current: 500_000, interval: .seconds(1))
        #expect(percent == 0)
    }

    @Test("interval <= 0 → nil，不除零、不崩")
    func nonPositiveIntervalIsNil() {
        #expect(CPUPercentCalculator.percent(previous: 0, current: 100, interval: .zero) == nil)
        #expect(CPUPercentCalculator.percent(previous: 0, current: 100, interval: .seconds(-1)) == nil)
    }

    @Test("间隔不是整数秒也能算对——0.5 秒间隔、250,000 微秒 → 50%")
    func handlesFractionalIntervals() {
        let percent = CPUPercentCalculator.percent(
            previous: 0,
            current: 250_000,
            interval: .milliseconds(500)
        )

        #expect(percent == 50)
    }
}
