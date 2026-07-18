import ContainerCore
import ContainerResource

/// **上游 `ContainerStats` → domain `ContainerStatsSample`。D1 的第五个落点。**
///
/// 全字段直搬，语义照抄上游（Day 9 计划 §0，已读源码 `ContainerStats.swift`）：
/// 全部 `UInt64?`，`nil` 与 `0` 不是同一件事，见 `ContainerStatsSample` 的类型文档。
/// 上游改字段，只有这个文件编译不过——和 `SnapshotMapper` 同一个理由。
enum StatsMapper {
    static func map(_ stats: ContainerStats) -> ContainerStatsSample {
        ContainerStatsSample(
            memoryUsageBytes: stats.memoryUsageBytes,
            memoryLimitBytes: stats.memoryLimitBytes,
            cpuUsageUsec: stats.cpuUsageUsec,
            networkRxBytes: stats.networkRxBytes,
            networkTxBytes: stats.networkTxBytes,
            blockReadBytes: stats.blockReadBytes,
            blockWriteBytes: stats.blockWriteBytes,
            numProcesses: stats.numProcesses
        )
    }
}
