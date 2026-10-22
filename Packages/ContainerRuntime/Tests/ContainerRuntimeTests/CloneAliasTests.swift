import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// Day 24 P3-alias（Plan 2026-10-21 §2.3-3）：上游 1.6.0 起附着可带 DNS aliases。
///
/// exact alias 在所有容器（含已停止）中唯一（上游 `AttachmentNameValidator`）——源容器还在，原样带过去 create 必 `.exists`。
/// 所以克隆**显式清空** aliases（与 MAC / hostname 同类），确认界面说一句「没复制」。只有数量上浮成 domain，名字留桥内。
@Suite("clone aliases：计数上浮、克隆清空、名字不上浮")
struct CloneAliasTests {

    static let uniqueAlias = "zq-unique-alias.example.test"

    private func snapshotWithAliases(_ perNetwork: [[String]]) throws -> ContainerSnapshot {
        var snapshot = try Fixtures.openConnector()
        snapshot.configuration.networks = perNetwork.enumerated().map { index, aliases in
            AttachmentConfiguration(
                network: "net\(index)",
                options: AttachmentOptions(hostname: "src", macAddress: nil, mtu: 1280, aliases: aliases)
            )
        }
        return snapshot
    }

    @Test("① 多个网络的 aliases 加总成 aliasCount")
    func countsAcrossNetworks() throws {
        let snapshot = try snapshotWithAliases([[Self.uniqueAlias, ".sub.example.test"], ["api.example.test"]])
        let template = try SnapshotMapper.cloneTemplate(from: snapshot)
        #expect(template.aliasCount == 3)
    }

    @Test("② 没有 aliases（真机 fixture）→ aliasCount 0，确认界面不出这一行")
    func noAliases() throws {
        let template = try SnapshotMapper.cloneTemplate(from: try Fixtures.openConnector())
        #expect(template.aliasCount == 0)
        #expect(ContainerCreationPresentation.cloneAliasNote(for: template) == nil)
    }

    @Test("③ 克隆结果的 aliases 为空，其余网络字段照现行规则")
    func sanitizeDropsAliases() throws {
        var source = try Fixtures.openConnector().configuration
        source.networks = [
            AttachmentConfiguration(
                network: "bridge",
                options: AttachmentOptions(hostname: "src", macAddress: nil, mtu: 1400, aliases: [Self.uniqueAlias])
            )
        ]
        let sanitized = CreationMapper.sanitizeForClone(
            source, newID: "clone-01", envOverride: nil, creationDate: Date(timeIntervalSince1970: 0)
        )
        let attachment = try #require(sanitized.networks.first)
        #expect(attachment.options.aliases.isEmpty)
        #expect(attachment.network == "bridge")
        #expect(attachment.options.hostname == "clone-01")
        #expect(attachment.options.mtu == 1400)
    }

    @Test("④ 有 aliases 才出文案，且文案不含任何 alias 名（四语）", arguments: ["en", "ja", "zh-Hans", "zh-Hant"])
    func noteNeverNamesAliases(language: String) throws {
        let template = try SnapshotMapper.cloneTemplate(from: try snapshotWithAliases([[Self.uniqueAlias]]))
        let note = try #require(ContainerCreationPresentation.cloneAliasNote(for: template, locale: Locale(identifier: language)))
        #expect(!note.isEmpty)
        #expect(!note.contains("zq-unique-alias"))
        if language != "en" {
            #expect(note != ContainerCreationPresentation.cloneAliasNote(for: template, locale: Locale(identifier: "en")))
        }
    }
}
