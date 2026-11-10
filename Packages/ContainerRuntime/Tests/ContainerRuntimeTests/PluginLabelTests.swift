import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// Day 29：runtime 边界读 `com.apple.container.plugin`，并在 start / stop 的第一个副作用之前拒绝插件管理的容器。
///
/// 靶子用 **1.6.0 真机录的 buildkit**（`plugin=builder`）——不是手写的标签。
@Suite("plugin 标签：映射与 start / stop 守卫")
struct PluginLabelTests {

    private let builder = ContainerPluginOwner(rawValue: "builder")

    private func client(_ upstream: FakeUpstreamClient, existingPaths: Set<String> = []) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(upstream: upstream, paths: FakePathChecker(existing: existingPaths), prober: FakeRuntimeProber.up)
    }

    private func buildkit(status: RuntimeStatus? = nil) throws -> ContainerSnapshot {
        var snapshot = try #require(Fixtures.recorded160().first { $0.id == "buildkit" })
        if let status { snapshot.status = status }
        return snapshot
    }

    private func id(_ raw: String) throws -> ContainerID { try #require(ContainerID(raw)) }

    // MARK: - 对照：domain 常量镜像上游

    @Test("ContainerPluginOwner.machine / .cluster 与上游 ResourcePluginValues 一致")
    func mirrorsUpstreamValues() {
        #expect(ContainerPluginOwner.machine.rawValue == ResourcePluginValues.machine)
        #expect(ContainerPluginOwner.cluster.rawValue == ResourcePluginValues.cluster)
    }

    @Test("映射读的就是上游 ResourceLabelKeys.plugin 这个键")
    func readsUpstreamKey() throws {
        var snapshot = try Fixtures.openConnector()
        snapshot.configuration.labels = [ResourceLabelKeys.plugin: ResourcePluginValues.cluster]
        #expect(try SnapshotMapper.map(snapshot).pluginOwner == .cluster)
    }

    // MARK: - 映射

    @Test("真机录的 buildkit → owner builder；open-connector → nil")
    func mapsRecordedLabels() throws {
        let mapped = try Fixtures.recorded160().map(SnapshotMapper.map)
        #expect(mapped.first { $0.id.rawValue == "buildkit" }?.pluginOwner == builder)
        #expect(mapped.first { $0.id.rawValue == "open-connector" }?.pluginOwner == nil)
    }

    @Test("值为空串也算插件管理（fail-safe）；别的标签不算")
    func emptyValueStillOwned() throws {
        var snapshot = try Fixtures.openConnector()
        snapshot.configuration.labels = [ResourceLabelKeys.plugin: ""]
        #expect(try SnapshotMapper.map(snapshot).pluginOwner == ContainerPluginOwner(rawValue: ""))

        snapshot.configuration.labels = [ResourceLabelKeys.role: ResourceRoleValues.builder]
        #expect(try SnapshotMapper.map(snapshot).pluginOwner == nil)
    }

    // MARK: - start 守卫

    @Test("停着的 plugin 容器：start 抛 pluginManaged，不发 launch")
    func startRefusesStopped() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try buildkit(status: .stopped)])
        let target = try id("buildkit")
        await #expect(throws: RuntimeError.pluginManaged(target, owner: builder)) {
            try await client(upstream).start(id: target)
        }
        #expect(await upstream.calls == [.get("buildkit")])
    }

    @Test("在跑的 plugin 容器：start 同样抛（守卫在幂等短路之前）")
    func startRefusesRunning() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try buildkit(status: .running)])
        let target = try id("buildkit")
        await #expect(throws: RuntimeError.pluginManaged(target, owner: builder)) {
            try await client(upstream).start(id: target)
        }
    }

    @Test("plugin + virtiofs 源缺失 → pluginManaged（守卫在 mount 校验之前，顺序钉死）")
    func pluginBeforeMountCheck() async throws {
        var snapshot = try Fixtures.needsExternalDisk()
        snapshot.configuration.labels = [ResourceLabelKeys.plugin: ResourcePluginValues.machine]
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        let target = try id(snapshot.id)
        await #expect(throws: RuntimeError.pluginManaged(target, owner: .machine)) {
            try await client(upstream).start(id: target)
        }
    }

    // MARK: - stop 守卫（restart 的前半段）

    @Test("在跑的 plugin 容器：stop 抛 pluginManaged，不发 upstream stop")
    func stopRefusesRunning() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try buildkit(status: .running)])
        let target = try id("buildkit")
        await #expect(throws: RuntimeError.pluginManaged(target, owner: builder)) {
            try await client(upstream).stop(id: target)
        }
        #expect(await upstream.calls == [.get("buildkit")])
    }

    @Test("普通容器照旧：在跑的 open-connector 能 stop")
    func plainContainerStillStops() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.openConnector()])
        try await client(upstream).stop(id: try id("open-connector"))
        #expect(await upstream.calls == [.get("open-connector"), .stop("open-connector")])
    }
}
