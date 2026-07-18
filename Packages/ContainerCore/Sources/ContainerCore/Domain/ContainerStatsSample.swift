/// 一次运行时统计的裸计数器快照——上游 `ContainerStats`（`ContainerResource` product）到此为止（D1）。
///
/// 字段语义照抄上游（Day 9 计划 §0，已读源码 `ContainerStats.swift`）：全部 `UInt64?`，
/// **`nil` 与 `0` 不是同一件事**——`0` 是「测到了，就是零」，`nil` 是「这次上游没给这个字段」。
/// 混为一谈会让 `StatsCollector` 把「没有数据」误读成「不耗资源」（P2-3 的同一条教训）。
///
/// 刻意不带 `id`：调用方（`stats(id:)` 的入参）已经知道自己问的是哪个容器，
/// 让样本再背一份 id 只是多一个「万一和调用参数对不上」的疑点，没有消费者需要它。
///
/// CPU% 不在这里：单个样本只是一个瞬时计数器读数，算不出速率——需要相邻两个样本
/// 加时间间隔（`CPUPercentCalculator`），那是 `StatsCollector` 的事，不是这个值类型的事。
public struct ContainerStatsSample: Sendable, Equatable {

    public let memoryUsageBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let cpuUsageUsec: UInt64?
    public let networkRxBytes: UInt64?
    public let networkTxBytes: UInt64?
    public let blockReadBytes: UInt64?
    public let blockWriteBytes: UInt64?
    public let numProcesses: UInt64?

    public init(
        memoryUsageBytes: UInt64? = nil,
        memoryLimitBytes: UInt64? = nil,
        cpuUsageUsec: UInt64? = nil,
        networkRxBytes: UInt64? = nil,
        networkTxBytes: UInt64? = nil,
        blockReadBytes: UInt64? = nil,
        blockWriteBytes: UInt64? = nil,
        numProcesses: UInt64? = nil
    ) {
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuUsageUsec = cpuUsageUsec
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.numProcesses = numProcesses
    }
}
