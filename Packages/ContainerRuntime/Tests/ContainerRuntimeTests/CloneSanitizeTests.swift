import ContainerCore
import ContainerizationExtras
import ContainerResource
import Foundation
import SystemPackage
import Testing

@testable import ContainerRuntime

/// clone sanitize（Day 16 T6.5，§3.2 表 / codex #3 P0）+ `create(clonedFrom:)` 接线。
///
/// **golden：逐字段断言** sanitize 后的 configuration——该清的清（networks/ports/sockets）、
/// 该重置的重置（id/creationDate）、该夹的夹（memory ≥200 MiB）、其余原样保留。
/// networks 清空⇒`macAddress` 不可能带过（§2：AttachmentConfiguration 带运行时分配 MAC）。
@Suite("clone sanitize：显式字段表 + 接线")
struct CloneSanitizeTests {

    /// 从真机录的 fixture 起手，塞入「该被 sanitize 掉」的字段，逼 sanitize 去清。
    private func sourceWithSanitizables() throws -> ContainerConfiguration {
        var config = try Fixtures.openConnector().configuration
        config.networks = [
            AttachmentConfiguration(
                network: "bridge",
                options: .init(
                    hostname: "src-host",
                    macAddress: try MACAddress("02:00:00:00:00:01"),
                    mtu: 1400
                )
            )
        ]
        config.publishedPorts = [
            try PublishPort(
                hostAddress: try IPAddress("127.0.0.1"),
                hostPort: 8080,
                containerPort: 80,
                proto: .tcp,
                count: 1
            )
        ]
        config.publishedSockets = [
            try PublishSocket(containerPath: FilePath("/run/c.sock"), hostPath: FilePath("/tmp/h.sock"))
        ]
        config.labels = ["team": "infra"]
        config.creationDate = Date(timeIntervalSince1970: 12345)
        return config
    }

    @Test("golden：id 重置、networks 重生（保拓扑/重置身份）、ports/sockets 清空、creationDate 重置、其余保留")
    func sanitizeClearsAndResets() throws {
        var source = try sourceWithSanitizables()
        source.resources.memoryInBytes = 2 * 1024 * 1024 * 1024   // 2 GiB，高于下限 → 应原样保留
        let now = Date(timeIntervalSince1970: 999_999)

        let sanitized = CreationMapper.sanitizeForClone(
            source, newID: "clone-01", envOverride: nil, creationDate: now
        )

        // 清空 / 重置
        #expect(sanitized.id == "clone-01")
        #expect(sanitized.publishedPorts.isEmpty)
        #expect(sanitized.publishedSockets.isEmpty)
        #expect(sanitized.creationDate == now)

        // networks 重生：保留网络名 + mtu（连接不丢，codex Round 2），重置 MAC（→nil，解冲突）+ hostname（→新 id）
        #expect(sanitized.networks.count == 1)
        let attachment = try #require(sanitized.networks.first)
        #expect(attachment.network == "bridge")                     // 拓扑保留 ⇒ 克隆体有网络
        #expect(attachment.options.macAddress == nil)               // ⇒ 源 MAC 不带过（服务端重分配）
        #expect(attachment.options.hostname == "clone-01")          // hostname → 新 id
        #expect(attachment.options.mtu == 1400)                     // mtu 保留

        // 原样保留
        #expect(sanitized.resources.memoryInBytes == 2 * 1024 * 1024 * 1024)
        #expect(sanitized.labels == ["team": "infra"])
        #expect(sanitized.image.reference == source.image.reference)
        #expect(sanitized.mounts.count == source.mounts.count)
        // envOverride == nil → 源 env 原样克隆（不进 UI）。
        #expect(sanitized.initProcess.environment == source.initProcess.environment)
    }

    @Test("源本就无网络（--network none）→ 克隆体保持无网络，不凭空塞一个")
    func sanitizeKeepsNoNetworkEmpty() throws {
        var source = try sourceWithSanitizables()
        source.networks = []   // 源是 --network none
        let now = Date(timeIntervalSince1970: 1)

        let sanitized = CreationMapper.sanitizeForClone(
            source, newID: "clone-nn", envOverride: nil, creationDate: now
        )

        #expect(sanitized.networks.isEmpty)   // 空进空出，不无中生有一个默认网络
    }

    @Test("resources 内存夹到 ≥200 MiB 下限（源值异常低时）")
    func sanitizeClampsMemoryToFloor() throws {
        var source = try sourceWithSanitizables()
        source.resources.memoryInBytes = 50 * 1024 * 1024   // 50 MiB，低于下限
        let now = Date(timeIntervalSince1970: 1)

        let sanitized = CreationMapper.sanitizeForClone(
            source, newID: "clone-02", envOverride: nil, creationDate: now
        )

        #expect(sanitized.resources.memoryInBytes == 200 * 1024 * 1024)   // 夹到 200 MiB
    }

    @Test("envOverride != nil → 替换 initProcess.environment（经 reveal 助手序列化成明文）")
    func sanitizeAppliesEnvOverride() throws {
        let source = try sourceWithSanitizables()
        let override = [
            try #require(EnvironmentVariable(parsing: "FOO=bar")),
            try #require(EnvironmentVariable(parsing: "BAZ=qux")),
        ]
        let now = Date(timeIntervalSince1970: 1)

        let sanitized = CreationMapper.sanitizeForClone(
            source, newID: "clone-03", envOverride: override, creationDate: now
        )

        #expect(sanitized.initProcess.environment == ["FOO=bar", "BAZ=qux"])
    }

    // MARK: - 接线

    private func client(upstream: FakeUpstreamClient) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(upstream: upstream, paths: FakePathChecker(), prober: FakeRuntimeProber.up)
    }

    @Test("接线：get(source) → sanitize → createFromConfiguration，id 回映、sanitize 结果透传到上游")
    func cloneWiringFetchesSanitizesCreates() async throws {
        let snapshot = try Fixtures.openConnector()
        let sourceID = try #require(ContainerID(snapshot.id))
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        let sut = client(upstream: upstream)

        let id = try await sut.create(
            clonedFrom: sourceID,
            name: try ContainerName("clone-01"),
            envOverride: nil
        )

        #expect(id == ContainerID("clone-01"))
        let last = await upstream.lastCloneConfiguration
        #expect(last?.id == "clone-01")           // sanitize 的 id 重置真的传给了上游
        // sanitize 的 networks 处理真的传给了上游：无论重生还是空，都不该带任何源 MAC。
        #expect(last?.networks.allSatisfy { $0.options.macAddress == nil } == true)
        let calls = await upstream.calls
        #expect(calls == [.get(sourceID.rawValue), .cloneCreate("clone-01")])
    }

    @Test("接线：上游回了个映不回 domain 的 id → 响亮失败")
    func cloneRejectsUnmappableID() async throws {
        let snapshot = try Fixtures.openConnector()
        let sourceID = try #require(ContainerID(snapshot.id))
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setCloneResultID("")   // 空 id 映不回
        let sut = client(upstream: upstream)

        await #expect(throws: RuntimeError.self) {
            _ = try await sut.create(clonedFrom: sourceID, name: try ContainerName("clone-01"), envOverride: nil)
        }
    }

    @Test("接线：clone create 卡死 → createTimeout 后返回，不冻住")
    func cloneHangReturnsAfterTimeout() async throws {
        let snapshot = try Fixtures.openConnector()
        let sourceID = try #require(ContainerID(snapshot.id))
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setHangCloneCreate(true)
        let sut = LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: FakeRuntimeProber.up,
            createTimeout: .milliseconds(50)
        )

        await #expect(throws: RuntimeError.self) {
            _ = try await sut.create(clonedFrom: sourceID, name: try ContainerName("clone-01"), envOverride: nil)
        }
    }
}
