import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// Day 24 P4（Plan 2026-10-21）：pin 升到 1.6.0 后，fixture 两头都要过——
/// 新运行时录的快照能 decode / 映射；1.1.0 时期录的旧快照在新上游类型下也仍能 decode（旧数据不会因升级读不出来）。
@Suite("fixture：1.6.0 录制可解、旧录制仍可解")
struct Fixture160Tests {

    @Test("1.6.0 录制：两条都 decode 并映射成 domain，状态对得上")
    func recorded160Maps() throws {
        var containers: [Container] = []
        for snapshot in try Fixtures.recorded160() {
            containers.append(try SnapshotMapper.map(snapshot))
        }
        #expect(containers.map(\.id.rawValue) == ["buildkit", "open-connector"])
        #expect(containers.map(\.state) == [.stopped, .running])
    }

    @Test("1.6.0 录制：密钥 key 名在、值是 SecretString（脱敏靶子仍有效）")
    func recorded160KeepsSecretKeys() throws {
        let snapshot = try #require(try Fixtures.recorded160().last)
        let container = try SnapshotMapper.map(snapshot)
        let keys = Set(container.environment.map(\.key))
        #expect(keys.contains("OOMOL_CONNECT_ENCRYPTION_KEY"))
        for variable in container.environment {
            #expect("\(variable.value)" == "<redacted>")
        }
    }

    @Test("1.6.0 录制：没有 aliases 的容器 aliasCount 为 0（编码时省略 aliases 键）")
    func recorded160HasNoAliases() throws {
        for snapshot in try Fixtures.recorded160() {
            #expect(try SnapshotMapper.cloneTemplate(from: snapshot).aliasCount == 0)
        }
    }

    @Test("旧录制（1.1.0 时期）在 1.6.0 类型下仍能 decode 并映射")
    func legacyRecordingsStillDecode() throws {
        let legacy = try Fixtures.snapshots("snapshots") + Fixtures.snapshots("virtiofs-container")
        #expect(legacy.count == 2)
        for snapshot in legacy {
            _ = try SnapshotMapper.map(snapshot)
            #expect(snapshot.configuration.networks.allSatisfy { $0.options.aliases.isEmpty })
        }
    }
}
