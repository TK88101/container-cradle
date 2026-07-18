import Foundation
import Testing

@testable import ContainerCore

/// `StatsPresentation`：CPU%/内存占位文案。**nil vs 0 的区分是判断，不是格式**（P2-3）——
/// 这条测试存在的全部意义就是钉死这条区分，别让它在某次「顺手简化」里被 `?? 0` 掉。
///
/// Day 14 起所有断言显式传 `en_US_POSIX` 并写死具体串（codex #10）：
/// 「非空即过」是被 DAY13 明令禁止的弱化。
@Suite("StatsPresentation")
struct StatsPresentationTests {

    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - CPU%

    @Test("nil → 占位 \"--\"，不是 \"0.0%\"")
    func cpuPercentNilIsPlaceholder() {
        #expect(StatsPresentation.cpuPercentText(nil, locale: posix) == "--")
    }

    @Test("0 → \"0.0%\"（量到了，真的空转，不是占位）")
    func cpuPercentZeroIsRealValue() {
        #expect(StatsPresentation.cpuPercentText(0, locale: posix) == "0.0%")
    }

    @Test("有值 → 一位小数百分比")
    func cpuPercentFormatsWithOneDecimal() {
        #expect(StatsPresentation.cpuPercentText(12.345, locale: posix) == "12.3%")
    }

    // MARK: - 内存

    @Test("used 为 nil → 占位 \"--\"")
    func memoryNilUsedIsPlaceholder() {
        #expect(StatsPresentation.memoryText(usedBytes: nil, limitBytes: 1_000, locale: posix) == "--")
    }

    @Test("有 used、limit 为 nil → 只显示 used，没有 \"/\"")
    func memoryWithoutLimitShowsUsedOnly() {
        let text = StatsPresentation.memoryText(usedBytes: 1_048_576, limitBytes: nil, locale: posix)
        #expect(text == "1 MB")
    }

    @Test("used 与 limit 都有 → \"used / limit\"")
    func memoryWithLimitShowsBoth() {
        let text = StatsPresentation.memoryText(usedBytes: 1_048_576, limitBytes: 2_097_152, locale: posix)
        #expect(text == "1 MB / 2 MB")
    }

    @Test("used 为 0 → 不是占位，是真实数字")
    func memoryZeroUsedIsRealValue() {
        let text = StatsPresentation.memoryText(usedBytes: 0, limitBytes: nil, locale: posix)
        #expect(text == "Zero kB")
    }

    // MARK: - ByteCountFormatStyle 迁移对照矩阵（codex #4）

    /// `ByteCountFormatter` → `ByteCountFormatStyle` 不是纯 locale 注入，输出可能漂。
    /// 2026-07-18 实测矩阵：`.memory` 口径在 MB/GB 档完全一致（66.8 MB / 512 GB），
    /// 差异仅 kB 档大小写（legacy `KB` → new `kB`）与 `Zero KB` → `Zero kB`——
    /// 不伤 stats 语义，**显式接受**并由本测试钉死。矩阵值与 volume 侧共用
    /// （512 GiB 稀疏上限 / 本机实测占用），两口径对照见 VolumePresentationTests。
    @Test(
        "迁移矩阵（.memory, en_US_POSIX）：0/1KiB/1MiB/70MB/512GiB 输出钉死",
        arguments: [
            (UInt64(0), "Zero kB"),
            (UInt64(1_024), "1 kB"),
            (UInt64(1_048_576), "1 MB"),
            (UInt64(70_078_464), "66.8 MB"),
            (UInt64(549_755_813_888), "512 GB"),
        ] as [(UInt64, String)]
    )
    func memoryMigrationMatrix(bytes: UInt64, expected: String) {
        #expect(StatsPresentation.memoryText(usedBytes: bytes, limitBytes: nil, locale: posix) == expected)
    }
}
