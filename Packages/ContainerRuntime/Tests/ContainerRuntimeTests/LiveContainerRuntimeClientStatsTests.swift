import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// `LiveContainerRuntimeClient.stats`——桥的接线（T10）。
///
/// `StatsMapperTests.swift` 已经守住了字段映射本身；这里守的是**接线**：
/// XPCTimeout 有没有真的包住这次调用、错误有没有走同一套 R14 判定（进程表是唯一权威）。
@Suite("LiveContainerRuntimeClient.stats：接线与超时")
struct LiveContainerRuntimeClientStatsTests {

    private func client(
        upstream: FakeUpstreamClient,
        prober: FakeRuntimeProber = .up,
        timeout: Duration = .seconds(5)
    ) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: prober,
            timeout: timeout
        )
    }

    private func id(_ raw: String) throws -> ContainerID {
        try #require(ContainerID(raw))
    }

    @Test("正常路径：上游快照 → 经 StatsMapper 映射成 domain 样本")
    func mapsUpstreamSnapshotToDomainSample() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setStatsResult(
            "cof-canary",
            ContainerStats(
                id: "cof-canary",
                memoryUsageBytes: 1024,
                memoryLimitBytes: 2048,
                cpuUsageUsec: 500_000,
                networkRxBytes: 10,
                networkTxBytes: 20,
                blockReadBytes: 30,
                blockWriteBytes: 40,
                numProcesses: 3
            )
        )

        let subject = client(upstream: upstream)
        let sample = try await subject.stats(id: try id("cof-canary"))

        #expect(sample.memoryUsageBytes == 1024)
        #expect(sample.memoryLimitBytes == 2048)
        #expect(sample.cpuUsageUsec == 500_000)
        #expect(sample.networkRxBytes == 10)
        #expect(sample.networkTxBytes == 20)
        #expect(sample.blockReadBytes == 30)
        #expect(sample.blockWriteBytes == 40)
        #expect(sample.numProcesses == 3)
    }

    // MARK: - P1-7：套 XPCTimeout

    /// 同款不可取消挂死——`Task.sleep` 测不出「压根没套超时」这个坑（T10 DoD 明确要求）。
    @Test("upstream.stats 挂死 → stats(id:) 仍在超时后返回，不冻住", .timeLimit(.minutes(1)))
    func hangsButTimesOut() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setHangStats(true)

        let subject = client(upstream: upstream, timeout: .milliseconds(20))

        await #expect(throws: RuntimeError.self) {
            _ = try await subject.stats(id: try id("cof-canary"))
        }
    }

    // MARK: - R14：错误映射走同一套进程表判定

    @Test("upstream.stats 失败 + prober 说 down → .runtimeUnavailable")
    func failureWithDeadRuntimeMapsToRuntimeUnavailable() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailStats(FakeUpstreamClient.Failure(label: "XPC connection invalid"))

        let subject = client(upstream: upstream, prober: .down)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            _ = try await subject.stats(id: try id("cof-canary"))
        }
    }

    @Test("upstream.stats 失败但 prober 说 running → 不是 runtimeUnavailable，是 transient")
    func failureWithLiveRuntimeIsNotBlamedOnRuntime() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailStats(FakeUpstreamClient.Failure(label: "XPC connection invalid"))

        let subject = client(upstream: upstream, prober: .up)
        let target = try id("cof-canary")

        do {
            _ = try await subject.stats(id: target)
            Issue.record("应当抛错")
        } catch {
            #expect(error != .runtimeUnavailable, "进程表说 apiserver 还在，不该赖运行时")
            #expect(FailureKind(from: error) == .transient)
        }
    }
}
