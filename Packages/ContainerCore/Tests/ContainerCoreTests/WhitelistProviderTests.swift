import Testing

@testable import ContainerCore

/// Day 22 simcodex R1（层级 #1）：「受管」判据只在 core 定义一处——supervisor 拉的与更新器冻结的必须是同一个集合。
@Suite("WhitelistProvider.enabledIDs：只算已启用的条目")
struct WhitelistProviderTests {

    @Test("disabled 的条目不算受管")
    func onlyEnabled() async throws {
        let a = try #require(ContainerID("open-connector"))
        let b = try #require(ContainerID("paused-one"))
        let whitelist = FixedWhitelist(list: [
            WhitelistEntry(id: a, enabled: true),
            WhitelistEntry(id: b, enabled: false),
        ])
        #expect(await whitelist.enabledIDs() == [a])
    }
}
