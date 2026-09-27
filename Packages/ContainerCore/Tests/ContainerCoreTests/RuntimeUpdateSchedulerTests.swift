import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// Day 22 T8：自动检查的节奏。启动 60 秒后第一次看、之后每小时看一次、距上次成功 ≥ 24h 才真的发请求（Plan §5.5）。
/// 时间全部手动推进（`ManualClock` + 同步推进的 `now`），一秒都不真睡。
@MainActor
@Suite("RuntimeUpdateScheduler：60 秒首检、每小时 tick、24h 到期、开关与忙碌")
struct RuntimeUpdateSchedulerTests {

    final class Time: @unchecked Sendable {
        let clock = ManualClock()
        let current = Mutex(Date(timeIntervalSince1970: 1_000_000))   // 与 ManualClock 的起点一致
        var now: @Sendable () -> Date { { [self] in self.current.withLock { $0 } } }
        func advance(_ seconds: TimeInterval) async {
            current.withLock { $0 = $0.addingTimeInterval(seconds) }
            await clock.advance(by: seconds)
        }
    }

    /// 让调度器的 Task 跑到下一个挂起点。
    func settle(_ h: RuntimeUpdateStoreTests.Harness) async {
        for _ in 0..<50 { await Task.yield() }
        await h.store.awaitOperationForTests()
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("启动 59 秒不检查，60 秒检查一次")
    func initialDelay() async throws {
        let time = Time()
        let h = try RuntimeUpdateStoreTests.Harness(feed: .release(UpdatePolicyTests.release(RuntimeUpdateStoreTests.v141)), now: time.now)
        let scheduler = RuntimeUpdateScheduler(store: h.store, clock: time.clock)
        scheduler.start()
        defer { scheduler.stop() }

        await settle(h)
        await time.advance(59)
        await settle(h)
        #expect(h.log.count("feed") == 0)

        await time.advance(1)
        await settle(h)
        #expect(h.log.count("feed") == 1)
    }

    /// A1：成功之后每小时 tick 都不发请求，满 24 小时那一 tick 才发 → 新版本最迟 25 小时内被发现。
    @Test("成功后 23 个整点不检查，第 24 小时检查")
    func dailyAfterSuccess() async throws {
        let time = Time()
        let h = try RuntimeUpdateStoreTests.Harness(feed: .release(UpdatePolicyTests.release(RuntimeUpdateStoreTests.v141)), now: time.now)
        let scheduler = RuntimeUpdateScheduler(store: h.store, clock: time.clock)
        scheduler.start()
        defer { scheduler.stop() }

        await settle(h)
        await time.advance(60)
        await settle(h)
        #expect(h.log.count("feed") == 1)

        for _ in 0..<23 {
            await time.advance(3600)
            await settle(h)
        }
        #expect(h.log.count("feed") == 1)

        await time.advance(3600)
        await settle(h)
        #expect(h.log.count("feed") == 2)
    }

    @Test("失败不算成功：下一个整点重试")
    func retriesAfterFailure() async throws {
        let time = Time()
        let h = try RuntimeUpdateStoreTests.Harness(feed: .failed(.network("offline")), now: time.now)
        let scheduler = RuntimeUpdateScheduler(store: h.store, clock: time.clock)
        scheduler.start()
        defer { scheduler.stop() }

        await settle(h)
        await time.advance(60)
        await settle(h)
        await time.advance(3600)
        await settle(h)
        #expect(h.log.count("feed") == 2)
    }

    /// A12：开关关掉，一次请求都不发。
    @Test("开关关闭 → 零请求")
    func disabled() async throws {
        let time = Time()
        let h = try RuntimeUpdateStoreTests.Harness(now: time.now)
        h.store.isAutomaticCheckEnabled = false
        #expect(h.prefs.isAutomaticCheckEnabled == false)   // 写入即落盘
        let scheduler = RuntimeUpdateScheduler(store: h.store, clock: time.clock)
        scheduler.start()
        defer { scheduler.stop() }

        await settle(h)
        await time.advance(60)
        await settle(h)
        await time.advance(3 * 3600)
        await settle(h)
        #expect(h.log.count("feed") == 0)
    }

    @Test("stop() 之后不再检查")
    func stopHalts() async throws {
        let time = Time()
        let h = try RuntimeUpdateStoreTests.Harness(now: time.now)
        let scheduler = RuntimeUpdateScheduler(store: h.store, clock: time.clock)
        scheduler.start()
        await settle(h)
        scheduler.stop()
        await time.advance(60)
        await settle(h)
        #expect(h.log.count("feed") == 0)
    }
}
