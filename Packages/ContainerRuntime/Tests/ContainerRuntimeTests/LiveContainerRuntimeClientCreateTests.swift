import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// `LiveContainerRuntimeClient.create(_:)`——能力 A 的桥接线（Day 16 T6）。
///
/// `CreationMapperTests` 已守 spec→inputs 的映射本身；这里守的是**接线**：
/// 调用有没有真的发生、id 有没有正确回映、错误有没有走 R14 判定、卡死有没有被 createTimeout 兜住。
@Suite("LiveContainerRuntimeClient.create：接线与超时")
struct LiveContainerRuntimeClientCreateTests {

    private func client(
        upstream: FakeUpstreamClient,
        prober: FakeRuntimeProber = .up,
        createTimeout: Duration = .seconds(5)
    ) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: prober,
            createTimeout: createTimeout
        )
    }

    private func spec(name: String = "web-01") throws -> ContainerCreationSpec {
        try ContainerCreationSpec(
            name: ContainerName(name),
            image: #require(ImageRef("docker.io/library/alpine:latest")),
            volumeMounts: [],
            environment: []
        )
    }

    @Test("正常路径：装配 create 并把上游 id 回映成 ContainerID")
    func createsAndMapsID() async throws {
        let upstream = FakeUpstreamClient()
        let sut = client(upstream: upstream)

        let id = try await sut.create(try spec(name: "web-01"))

        #expect(id == ContainerID("web-01"))
        let calls = await upstream.calls
        #expect(calls == [.create("web-01")])
    }

    @Test("上游失败 → 经 R14 判定映成 domain 错误")
    func mapsUpstreamFailure() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailCreate(FakeUpstreamClient.Failure(label: "boom"))
        let sut = client(upstream: upstream, prober: .up)

        await #expect(throws: RuntimeError.self) {
            _ = try await sut.create(try spec())
        }
    }

    @Test("上游回了个映不回 domain 的 id → 响亮失败，不静默")
    func rejectsUnmappableID() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setCreateResultID("")   // 空 id 映不回 ContainerID
        let sut = client(upstream: upstream)

        await #expect(throws: RuntimeError.self) {
            _ = try await sut.create(try spec())
        }
    }

    @Test("create 卡死 → 在 createTimeout 后返回，不冻住")
    func createHangReturnsAfterTimeout() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setHangCreate(true)
        let sut = client(upstream: upstream, createTimeout: .milliseconds(50))

        await #expect(throws: RuntimeError.self) {
            _ = try await sut.create(try spec())
        }
    }
}
