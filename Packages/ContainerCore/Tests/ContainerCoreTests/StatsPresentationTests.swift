import Testing

@testable import ContainerCore

/// `StatsPresentation`：CPU%/内存占位文案。**nil vs 0 的区分是判断，不是格式**（P2-3）——
/// 这条测试存在的全部意义就是钉死这条区分，别让它在某次「顺手简化」里被 `?? 0` 掉。
@Suite("StatsPresentation")
struct StatsPresentationTests {

    // MARK: - CPU%

    @Test("nil → 占位 \"--\"，不是 \"0.0%\"")
    func cpuPercentNilIsPlaceholder() {
        #expect(StatsPresentation.cpuPercentText(nil) == "--")
    }

    @Test("0 → \"0.0%\"（量到了，真的空转，不是占位）")
    func cpuPercentZeroIsRealValue() {
        #expect(StatsPresentation.cpuPercentText(0) == "0.0%")
    }

    @Test("有值 → 一位小数百分比")
    func cpuPercentFormatsWithOneDecimal() {
        #expect(StatsPresentation.cpuPercentText(12.345) == "12.3%")
    }

    // MARK: - 内存

    @Test("used 为 nil → 占位 \"--\"")
    func memoryNilUsedIsPlaceholder() {
        #expect(StatsPresentation.memoryText(usedBytes: nil, limitBytes: 1_000) == "--")
    }

    @Test("有 used、limit 为 nil → 只显示 used，没有 \"/\"")
    func memoryWithoutLimitShowsUsedOnly() {
        let text = StatsPresentation.memoryText(usedBytes: 1_048_576, limitBytes: nil)
        #expect(!text.isEmpty)
        #expect(!text.contains("/"))
    }

    @Test("used 与 limit 都有 → \"used / limit\"")
    func memoryWithLimitShowsBoth() {
        let text = StatsPresentation.memoryText(usedBytes: 1_048_576, limitBytes: 2_097_152)
        #expect(text.contains("/"))
    }

    @Test("used 为 0 → 不是占位，是真实数字")
    func memoryZeroUsedIsRealValue() {
        let text = StatsPresentation.memoryText(usedBytes: 0, limitBytes: nil)
        #expect(text != "--")
    }
}
