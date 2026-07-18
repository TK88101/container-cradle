import Foundation
import Testing

@testable import ContainerCore

/// `StatsWindowStore`：stats 窗口的 UI 编排。搬进 core（A1）之后第一次有测试覆盖。
///
/// 首样本占位 / 第二样本有值这两条依赖 `StatsCollector` 内部真实的 1 秒轮询间隔
/// （`start()` 没有暴露注入时钟的口子——那是它的既有设计，这里不为了测试去改生产签名）。
/// 用真实时间等一拍，比引入一个只有测试用得到的构造参数更小的改动面。
@MainActor
@Suite("StatsWindowStore：首样本占位 + P1-9 单飞")
struct StatsWindowStoreTests {

    /// 用真实时间轮询——`StatsWindowStore.start()` 内部是 `Task.sleep(for: .seconds(1))`，
    /// `Task.yield()` 推不动一个真实计时器，必须真的等。
    private static func waitUntilRealTime(
        timeoutSeconds: Double = 3,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("条件在预期时间内没有成立（真实时间等待超时）")
    }

    /// `Task.yield()` 在这个套件里不够用：同一 suite 内多个 `@Test` 并发跑，紧凑的
    /// yield 自旋会跟其他测试抢线程池，反而让真正该被调度的后台 Task（跨 actor 的
    /// `StatsCollector.poll()`）迟迟轮不到——实测会假红。换成真的 `Task.sleep`，
    /// 把线程还给调度器，才稳定。
    private static func waitUntil(
        _ condition: @escaping () -> Bool,
        iterations: Int = 2_000
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("条件在预期时间内没有成立")
    }

    @Test("首样本：cpuPercent 占位为 nil；第二样本：真的有值")
    func firstSampleIsPlaceholderSecondSampleHasValue() async {
        let id = ContainerID("demo")!
        let client = FakeContainerRuntimeClient(containers: [])
        await client.setStatsSamples([
            ContainerStatsSample(memoryUsageBytes: 100, cpuUsageUsec: 1_000),
            ContainerStatsSample(memoryUsageBytes: 200, cpuUsageUsec: 2_000),
        ])

        let store = StatsWindowStore(id: id, client: client)
        store.start()

        await Self.waitUntil { store.snapshot != nil }
        #expect(store.snapshot?.cpuPercent == nil, "首样本无从比较，必须是占位 nil，不是 0")

        await Self.waitUntilRealTime { store.snapshot?.cpuPercent != nil }
        #expect(store.snapshot?.cpuPercent != nil)

        store.stop()
    }

    @Test("stop() 后 snapshot 不再更新")
    func stopFreezesSnapshot() async {
        let id = ContainerID("demo")!
        let client = FakeContainerRuntimeClient(containers: [])
        await client.setStatsSamples([ContainerStatsSample(memoryUsageBytes: 42)])

        let store = StatsWindowStore(id: id, client: client)
        store.start()

        await Self.waitUntil { store.snapshot != nil }
        store.stop()

        let frozen = store.snapshot
        // 给「万一还在跑」的轮询一点时间，确认它真的不再写回。
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.snapshot == frozen)
    }

    // MARK: - P1-9：stop() 之后的旧 poll 结果不许覆盖新会话

    private actor GatedStatsClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {
        private var pending: [CheckedContinuation<ContainerStatsSample, Never>] = []

        var pendingCount: Int { pending.count }

        func list() async throws(RuntimeError) -> [Container] { [] }
        func start(id: ContainerID) async throws(RuntimeError) {}
        func stop(id: ContainerID) async throws(RuntimeError) {}

        func followLogs(id: ContainerID) async throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func stats(id: ContainerID) async throws(RuntimeError) -> ContainerStatsSample {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
            }
        }

        func complete(_ index: Int, with sample: ContainerStatsSample) {
            pending[index].resume(returning: sample)
        }
    }

    private static func waitForPending(_ count: Int, on client: GatedStatsClient) async {
        for _ in 0..<20_000 {
            if await client.pendingCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 stats 请求")
    }

    @Test("stop() 之后重开：旧会话（已 stop）的 stats 结果后到，也不许覆盖新会话")
    func staleSessionAfterStopDoesNotOverwriteNewer() async {
        let id = ContainerID("demo")!
        let client = GatedStatsClient()
        let store = StatsWindowStore(id: id, client: client)

        // 会话 1：start，等它的 stats() 请求挂起。
        store.start()
        await Self.waitForPending(1, on: client)

        // 关掉会话 1，立刻开会话 2；它的 stats() 也会挂起（第 2 个在途请求）。
        store.stop()
        store.start()
        await Self.waitForPending(2, on: client)

        // 会话 2 先返回，snapshot 落地。
        let newer = ContainerStatsSample(memoryUsageBytes: 999)
        await client.complete(1, with: newer)
        await Self.waitUntil { store.snapshot?.memoryUsedBytes == 999 }

        // 会话 1（已经 stop 过）的结果后到——它不该覆盖会话 2 已经落地的值。
        let stale = ContainerStatsSample(memoryUsageBytes: 111)
        await client.complete(0, with: stale)

        for _ in 0..<50 { await Task.yield() }

        #expect(store.snapshot?.memoryUsedBytes == 999)

        store.stop()
    }
}
