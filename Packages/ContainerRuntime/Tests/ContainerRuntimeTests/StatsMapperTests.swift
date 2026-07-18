import ContainerCore
import ContainerResource
import Testing

@testable import ContainerRuntime

/// **上游 `ContainerStats` → domain `ContainerStatsSample`。D1 的第五个落点。**
@Suite("StatsMapper：上游 ContainerStats → domain ContainerStatsSample")
struct StatsMapperTests {

    @Test("全字段有值 → 原样搬运，不做任何计算")
    func mapsAllFieldsVerbatim() {
        let upstream = ContainerStats(
            id: "open-connector",
            memoryUsageBytes: 123,
            memoryLimitBytes: 456,
            cpuUsageUsec: 789,
            networkRxBytes: 111,
            networkTxBytes: 222,
            blockReadBytes: 333,
            blockWriteBytes: 444,
            numProcesses: 5
        )

        let sample = StatsMapper.map(upstream)

        #expect(sample.memoryUsageBytes == 123)
        #expect(sample.memoryLimitBytes == 456)
        #expect(sample.cpuUsageUsec == 789)
        #expect(sample.networkRxBytes == 111)
        #expect(sample.networkTxBytes == 222)
        #expect(sample.blockReadBytes == 333)
        #expect(sample.blockWriteBytes == 444)
        #expect(sample.numProcesses == 5)
    }

    /// `nil` 与 `0` 不是同一件事（`ContainerStatsSample` 的类型文档）——mapper 不许把
    /// 「上游没给这个字段」悄悄变成「测到了，是零」。
    @Test("全字段 nil → 原样保留 nil，不被映射成 0")
    func preservesAllNilFields() {
        let upstream = ContainerStats(
            id: "cof-canary",
            memoryUsageBytes: nil,
            memoryLimitBytes: nil,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: nil
        )

        let sample = StatsMapper.map(upstream)

        #expect(sample.memoryUsageBytes == nil)
        #expect(sample.memoryLimitBytes == nil)
        #expect(sample.cpuUsageUsec == nil)
        #expect(sample.networkRxBytes == nil)
        #expect(sample.networkTxBytes == nil)
        #expect(sample.blockReadBytes == nil)
        #expect(sample.blockWriteBytes == nil)
        #expect(sample.numProcesses == nil)
    }

    @Test("上游的 id 字段不参与映射——ContainerStatsSample 刻意不带 id")
    func idIsNotCarriedOver() {
        let upstream = ContainerStats(
            id: "irrelevant-to-the-sample",
            memoryUsageBytes: 1,
            memoryLimitBytes: nil,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: nil
        )

        // 编译期证明：ContainerStatsSample.init 根本没有 id 参数——这里只是补一条
        // 运行期证据，确认 mapper 没有意外地把 id 塞进某个别的字段。
        let sample = StatsMapper.map(upstream)
        #expect(sample.memoryUsageBytes == 1)
    }
}
