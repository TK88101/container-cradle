/// CPU 占用百分比——照抄上游数学（已核实源码 `ContainerStats.swift:206 calculateCPUPercent`）：
/// 两次相邻 `cpuUsageUsec` 样本的差分，除以采样间隔。**100% = 一个满载核**（上游语义）。
///
/// ## 为什么用 `Duration` 而不是裸数字（P1-8，codex review 定案）
///
/// `cpuUsageUsec` 是微秒，一个天真的实现会写 `Double(delta) / interval`（`interval` 若是秒），
/// 字面上就差了 1e6 倍——两个数量级不同的裸数字混在一个表达式里，量纲错误在编译期和运行期
/// 都不会报警，只会在真机上把 CPU% 显示成荒谬的数字。这里把差分与间隔都先转成 `Duration`，
/// 用 `Duration / Duration -> Double`（无量纲比值）求比例，量纲自洽是 `Duration` 类型本身保证的，
/// 不是靠「记得除以 1e6」。
public enum CPUPercentCalculator {

    /// - Parameters:
    ///   - previous: 上一次样本的 `cpuUsageUsec`。
    ///   - current: 这一次样本的 `cpuUsageUsec`。
    ///   - interval: 两次采样之间的真实间隔。
    ///
    /// 四种情形（P2-3 裁决：reset 与 idle 必须区分）：
    /// - 任一样本缺 `cpuUsageUsec` → `nil`（占位：不知道，不是「不耗 CPU」）。
    /// - `current < previous`（计数器被重置——容器在两次采样之间重启过）→ `nil`（同上，占位）。
    /// - `current == previous`（真的空转）→ `0`。
    /// - `interval <= .zero`（时钟没有前进，没法算速率）→ `nil`，不崩、不除零。
    public static func percent(
        previous: UInt64?,
        current: UInt64?,
        interval: Duration
    ) -> Double? {
        guard let previous, let current else { return nil }
        guard interval > .zero else { return nil }
        guard current >= previous else { return nil }
        guard current > previous else { return 0 }

        let cpuTime = Duration.microseconds(current - previous)
        let ratio = cpuTime / interval

        return ratio * 100
    }
}
