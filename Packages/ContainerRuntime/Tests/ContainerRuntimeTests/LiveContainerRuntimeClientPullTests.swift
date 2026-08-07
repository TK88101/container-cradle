import ContainerCore
import Foundation
import TerminalProgress
import Testing

@testable import ContainerRuntime

/// `LiveContainerRuntimeClient.pullImage(_:)`——image pull 的桥接线（Day 16 T6.2）。
///
/// `PullMapperTests` 已守「一批事件怎么折叠」；这里守的是**跨批的桥**：
/// 上游反向 XPC 分批投递 → 累积器逐批喂 `PullMapper.folding` → 折叠出的快照 yield 进流。
/// **T2b 的「字节假 0」正是死在这条跨批累积上**（只数 set* 漏了 add*）——所以这里必须有一条
/// 「add* 跨两批累加」的回归，且它走的是真桥，不是 mapper 的纯函数。
@Suite("LiveContainerRuntimeClient.pull：跨批桥接与错误映射")
struct LiveContainerRuntimeClientPullTests {

    private func client(upstream: FakeUpstreamClient, prober: FakeRuntimeProber = .up) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: prober
        )
    }

    private func ref() throws -> ImageRef {
        try #require(ImageRef("docker.io/library/alpine:latest"))
    }

    private func collect(_ stream: AsyncThrowingStream<PullProgress, any Error>) async throws -> [PullProgress] {
        var out: [PullProgress] = []
        for try await progress in stream { out.append(progress) }
        return out
    }

    @Test("跨批累积：add* 分两批投递，字节要累加，不是每批归零（T2b 回归）")
    func streamsFoldedProgressAcrossBatches() async throws {
        let upstream = FakeUpstreamClient()
        // 第一批设总量 + 增量 30；第二批再增量 70。字节要跨批累到 100。
        await upstream.setPullBatches([
            [.setTotalSize(100), .addSize(30)],
            [.addSize(70)],
        ])
        let sut = client(upstream: upstream)

        let snapshots = try await collect(try sut.pullImage(try ref()))

        let last = try #require(snapshots.last)
        #expect(last.bytes == 100)          // 30 + 70 跨批累加，不是被第二批覆盖成 70
        #expect(last.totalBytes == 100)
        let calls = await upstream.calls
        #expect(calls == [.pull("docker.io/library/alpine:latest")])
    }

    @Test("正常收官：批投完 + 上游返回 → 流正常结束，逐批都 yield 了快照")
    func finishesNormallyOnCompletion() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setPullBatches([
            [.setTotalItems(3), .addItems(1)],
            [.addItems(1)],
            [.addItems(1)],
        ])
        let sut = client(upstream: upstream)

        let snapshots = try await collect(try sut.pullImage(try ref()))

        #expect(snapshots.count == 3)                 // 每批一个快照
        #expect(snapshots.last?.items == 3)           // 项数跨批累到 3
        #expect(snapshots.last?.totalItems == 3)
    }

    @Test("上游失败 → 经 R14 判定映成 domain 错误，从流里抛出")
    func mapsUpstreamFailureIntoStream() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailPull(FakeUpstreamClient.Failure(label: "boom"))
        let sut = client(upstream: upstream, prober: .up)

        await #expect(throws: RuntimeError.self) {
            _ = try await self.collect(try sut.pullImage(try self.ref()))
        }
    }

    @Test("phase 取 setDescription（pull 发的 Fetching/Unpacking image）")
    func tracksPhaseFromDescription() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setPullBatches([
            [.setDescription("Fetching image"), .setTotalSize(10)],
            [.setDescription("Unpacking image"), .setSize(10)],
        ])
        let sut = client(upstream: upstream)

        let snapshots = try await collect(try sut.pullImage(try ref()))

        #expect(snapshots.last?.phase == "Unpacking image")   // 最后一个覆盖
    }
}
