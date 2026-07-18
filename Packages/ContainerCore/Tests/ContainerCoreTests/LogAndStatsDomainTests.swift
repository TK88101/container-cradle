import Testing

@testable import ContainerCore

/// M4 新增域类型的最小集：`LogLine` / `RedactedLogLine` / `ContainerStatsSample` /
/// `ContainerStatsSnapshot`。这些是纯值类型，行为都委托给别的类型测（`LogRedactor`、
/// `LogRingBuffer`、`CPUPercentCalculator`、`StatsCollector`）——这里只钉住构造与相等性。
@Suite("Log/Stats 域类型：构造与相等性")
struct LogAndStatsDomainTests {

    @Test("LogLine 默认 source 是 stdout，sequence 默认为 nil")
    func logLineDefaults() {
        let line = LogLine(text: "hello")
        #expect(line.source == .stdout)
        #expect(line.sequence == nil)
    }

    @Test("LogLine 按值相等")
    func logLineEquality() {
        #expect(LogLine(text: "a") == LogLine(text: "a"))
        #expect(LogLine(text: "a") != LogLine(text: "b"))
    }

    @Test("RedactedLogLine 携带 id，供 UI 稳定去重/排序")
    func redactedLogLineCarriesID() {
        let line = RedactedLogLine(id: 7, text: "hello", source: .stdout)
        #expect(line.id == 7)
        #expect(line.text == "hello")
    }

    @Test("ContainerStatsSample 全字段默认 nil——「没测到」不是 0")
    func containerStatsSampleDefaultsToNil() {
        let sample = ContainerStatsSample()
        #expect(sample.memoryUsageBytes == nil)
        #expect(sample.cpuUsageUsec == nil)
        #expect(sample.numProcesses == nil)
    }

    @Test("ContainerStatsSample 按值相等")
    func containerStatsSampleEquality() {
        let a = ContainerStatsSample(memoryUsageBytes: 100, cpuUsageUsec: 50)
        let b = ContainerStatsSample(memoryUsageBytes: 100, cpuUsageUsec: 50)
        let c = ContainerStatsSample(memoryUsageBytes: 200, cpuUsageUsec: 50)

        #expect(a == b)
        #expect(a != c)
    }

    @Test("ContainerStatsSnapshot 按值相等，含 sparkline 数组")
    func containerStatsSnapshotEquality() {
        let a = ContainerStatsSnapshot(cpuPercent: 50, memoryUsedBytes: 1, memoryLimitBytes: 2, cpuSparkline: [50])
        let b = ContainerStatsSnapshot(cpuPercent: 50, memoryUsedBytes: 1, memoryLimitBytes: 2, cpuSparkline: [50])
        let c = ContainerStatsSnapshot(cpuPercent: nil, memoryUsedBytes: 1, memoryLimitBytes: 2, cpuSparkline: [])

        #expect(a == b)
        #expect(a != c)
    }
}
