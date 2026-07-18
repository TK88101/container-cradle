import Foundation
import Testing

@testable import ContainerCore

/// 一个**可以精确控制 `stats(id:)` 返回时机**的运行时——同 `ContainerListStoreTests`
/// 的 `GatedRuntimeClient` 套路：把每次调用挂在 continuation 上，由测试显式决定谁先返回，
/// 让「后发起的先返回」这个顺序变成**确定**的，不是撞运气撞出来的。
private actor GatedStatsClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private var pending: [CheckedContinuation<ContainerStatsSample, Never>] = []

    var pendingCount: Int { pending.count }

    func list() throws(RuntimeError) -> [Container] { [] }
    func start(id: ContainerID) throws(RuntimeError) {}
    func stop(id: ContainerID) throws(RuntimeError) {}

    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stats(id: ContainerID) async throws(RuntimeError) -> ContainerStatsSample {
        await withCheckedContinuation { pending.append($0) }
    }

    /// 放行第 `index` 次发起的调用（0 起），让它返回 `sample`。
    func complete(_ index: Int, with sample: ContainerStatsSample) {
        pending[index].resume(returning: sample)
    }
}

@Suite("StatsCollector：首样本占位、sparkline 有界、poll 失败保留历史、epoch 跨 await")
struct StatsCollectorTests {

    private static func waitForPending(_ count: Int, on client: GatedStatsClient) async {
        for _ in 0..<10_000 {
            if await client.pendingCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途请求——collector 可能压根没发起调用")
    }

    @Test("首样本：cpuPercent 是 nil（占位），mem 字段已经有值")
    func firstSampleCPUIsPlaceholder() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.setStatsSamples([
            ContainerStatsSample(memoryUsageBytes: 1024, memoryLimitBytes: 2048, cpuUsageUsec: 1_000_000)
        ])
        let collector = StatsCollector(client: client, id: ContainerID("c")!, clock: ManualClock())

        await collector.poll()

        let latest = await collector.latest
        #expect(latest?.cpuPercent == nil)
        #expect(latest?.memoryUsedBytes == 1024)
        #expect(latest?.memoryLimitBytes == 2048)
        #expect(latest?.cpuSparkline.isEmpty == true, "首样本没有可比较的前一个样本，不该进 sparkline")
    }

    @Test("第二样本：有值，且用了两次采样之间的真实间隔")
    func secondSampleHasValue() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.setStatsSamples([
            ContainerStatsSample(cpuUsageUsec: 0),
            ContainerStatsSample(cpuUsageUsec: 1_000_000),
        ])
        let clock = ManualClock()
        let collector = StatsCollector(client: client, id: ContainerID("c")!, clock: clock)

        await collector.poll()
        await clock.advance(by: 1)
        await collector.poll()

        let latest = await collector.latest
        #expect(latest?.cpuPercent == 100)
        #expect(latest?.cpuSparkline == [100])
    }

    @Test("sparkline 超过上限 → 丢最旧，只留最近 N 个")
    func sparklineDropsOldestBeyondLimit() async {
        let client = FakeContainerRuntimeClient(containers: [])
        // 3 个样本 → 2 次差分 → sparkline 最多 2 个点；上限设成 1，验证只留最后一个。
        await client.setStatsSamples([
            ContainerStatsSample(cpuUsageUsec: 0),
            ContainerStatsSample(cpuUsageUsec: 1_000_000),
            ContainerStatsSample(cpuUsageUsec: 3_000_000),
        ])
        let clock = ManualClock()
        let collector = StatsCollector(client: client, id: ContainerID("c")!, clock: clock, sparklineLimit: 1)

        await collector.poll()
        await clock.advance(by: 1)
        await collector.poll()
        await clock.advance(by: 1)
        await collector.poll()

        let latest = await collector.latest
        #expect(latest?.cpuSparkline == [200], "应当只留最近一个点（丢掉更早的 100）")
    }

    @Test("poll 失败一次 → 保留上一次的历史，不清空 latest")
    func pollFailurePreservesHistory() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.setStatsSamples([ContainerStatsSample(memoryUsageBytes: 999)])
        let clock = ManualClock()
        let collector = StatsCollector(client: client, id: ContainerID("c")!, clock: clock)

        await collector.poll()
        let afterSuccess = await collector.latest
        #expect(afterSuccess?.memoryUsedBytes == 999)

        await client.inject(.operationFailed(reason: "xpc hiccup"), for: .stats)
        await clock.advance(by: 1)
        await collector.poll()

        let afterFailure = await collector.latest
        #expect(afterFailure == afterSuccess, "失败不该动 latest——保留上一次成功的历史")
    }

    @Test("reset() 之后：CPU% 又从占位起算，不沿用重开前的旧样本")
    func resetRestartsFromPlaceholder() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.setStatsSamples([
            ContainerStatsSample(cpuUsageUsec: 0),
            ContainerStatsSample(cpuUsageUsec: 1_000_000),
        ])
        let clock = ManualClock()
        let collector = StatsCollector(client: client, id: ContainerID("c")!, clock: clock)

        await collector.poll()
        await clock.advance(by: 1)
        await collector.poll()
        #expect(await collector.latest?.cpuPercent == 100)

        await collector.reset()
        #expect(await collector.latest == nil)

        await client.setStatsSamples([ContainerStatsSample(cpuUsageUsec: 500_000)])
        await collector.poll()

        #expect(await collector.latest?.cpuPercent == nil, "重开之后的首样本，仍然应当是占位")
    }

    /// ★ P1-9：`poll()` 跨 `await` 后必须重新证明自己还活在同一个世界里。
    ///
    /// 场景：poll A 先发起（epoch=1），还卡在 `stats()` 里没回来；poll B 后发起（epoch=2）
    /// 且**先**拿到结果、先落地。随后 poll A 的结果才姗姗来迟——它必须被识别为「迟到」而丢弃，
    /// 不能用一份更旧的数据覆盖 B 已经落地的更新数据。
    @Test("迟到的 poll 结果被丢弃，不覆盖更新的 latest（epoch 校验）")
    func staleResultDoesNotOverwriteNewerLatest() async {
        let client = GatedStatsClient()
        let clock = ManualClock()
        let collector = StatsCollector(client: client, id: ContainerID("c")!, clock: clock)

        let pollA = Task { await collector.poll() }
        await Self.waitForPending(1, on: client)

        let pollB = Task { await collector.poll() }
        await Self.waitForPending(2, on: client)

        // 后发起的先返回。
        await client.complete(1, with: ContainerStatsSample(memoryUsageBytes: 222))
        await pollB.value

        // 先发起的后返回——它已经被 B 追过了，落地时必须被 epoch 校验拦下。
        await client.complete(0, with: ContainerStatsSample(memoryUsageBytes: 111))
        await pollA.value

        let latest = await collector.latest
        #expect(latest?.memoryUsedBytes == 222, "迟到的 A 不该覆盖已经落地的 B")
    }
}
