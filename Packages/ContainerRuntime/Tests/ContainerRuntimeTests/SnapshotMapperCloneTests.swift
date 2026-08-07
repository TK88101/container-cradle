import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// `SnapshotMapper.cloneTemplate` + `LiveContainerRuntimeClient.cloneTemplate`（Day 16 T6.4）。
///
/// clone 预填的**纯提取**：image + env（保持 `SecretString`、不 reveal）+ 按挂载类型三桶计数。
/// fixture 是真机录的（Fixtures 注释）——上游改字段这里也会红。
@Suite("cloneTemplate：image + env(SecretString) + 挂载摘要计数")
struct SnapshotMapperCloneTests {

    @Test("openConnector：image 原样、env 13 条、单 volume 挂载")
    func openConnectorTemplate() throws {
        let template = try SnapshotMapper.cloneTemplate(from: try Fixtures.openConnector())

        #expect(template.image == ImageRef("ghcr.io/oomol-lab/open-connector:latest"))
        // 13 条原始 env 里有 1 条非 `KEY=VALUE`，被 `environment(from:)` 的 compactMap 丢弃 → 12
        // （与 list 映射同一条既有脱敏行为，不是 clone 特有）。
        #expect(template.environment.count == 12)
        #expect(template.mountSummary == MountSummary(volumeCount: 1, bindCount: 0, tmpfsCount: 0))
    }

    @Test("virtiofs 容器：virtiofs 计入 bind、volume 计入 volume（1 bind + 1 volume）")
    func virtiofsTemplateCounts() throws {
        let template = try SnapshotMapper.cloneTemplate(from: try Fixtures.needsExternalDisk())

        #expect(template.mountSummary == MountSummary(volumeCount: 1, bindCount: 1, tmpfsCount: 0))
        #expect(template.mountSummary.total == 2)
    }

    @Test("env 值保持 SecretString——预填模板里也是 <redacted>，不 reveal（D2）")
    func environmentStaysSecret() throws {
        let template = try SnapshotMapper.cloneTemplate(from: try Fixtures.openConnector())

        // 每一项的值插值出来都是脱敏串——明文根本走不出来（要明文得显式 .reveal()，此路径无）。
        for variable in template.environment {
            #expect("\(variable.value)" == "<redacted>")
        }
    }

    @Test("桥接线：cloneTemplate 走 get 一次，映射后返回 domain 模板")
    func liveClientFetchesAndMaps() async throws {
        let snapshot = try Fixtures.openConnector()
        let id = try #require(ContainerID(snapshot.id))
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        let sut = LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: FakeRuntimeProber.up
        )

        let template = try await sut.cloneTemplate(for: id)

        #expect(template.image == ImageRef("ghcr.io/oomol-lab/open-connector:latest"))
        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue)])
    }
}
