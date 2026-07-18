/// `StatsCollector` 每次 poll 之后算出来的、UI 直接消费的快照。
///
/// - `cpuPercent`：`nil` = 占位（首样本，或计数器 reset），不是 0%——0% 是「量到了，真的空转」。
///   两者混为一谈会让用户把「还没测出来」读成「容器不干活」（P2-3）。
/// - `cpuSparkline`：`cpuPercent` 的历史，只收有值的样本（`nil` 不进历史——sparkline 是曲线，
///   没有「点」的地方没法画）。**有界**，见 `StatsCollector` 的 `sparklineLimit`。
public struct ContainerStatsSnapshot: Sendable, Equatable {

    public let cpuPercent: Double?
    public let memoryUsedBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let cpuSparkline: [Double]

    public init(
        cpuPercent: Double?,
        memoryUsedBytes: UInt64?,
        memoryLimitBytes: UInt64?,
        cpuSparkline: [Double]
    ) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuSparkline = cpuSparkline
    }
}
