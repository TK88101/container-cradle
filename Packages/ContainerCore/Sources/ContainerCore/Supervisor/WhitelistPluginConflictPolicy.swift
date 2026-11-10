/// 白名单里一条指向**插件管理容器**的条目——supervisor 会跳过它（Day 29）。
public struct WhitelistPluginConflict: Sendable, Equatable {
    public let entry: WhitelistEntry
    public let owner: ContainerPluginOwner

    public init(entry: WhitelistEntry, owner: ContainerPluginOwner) {
        self.entry = entry
        self.owner = owner
    }
}

/// 「白名单里哪些条目是 supervisor 会跳过的 plugin 容器？」——菜单冲突区块的判据。
///
/// 只在列表**权威**（`.loaded`）时成立，与 `WhitelistOrphanPolicy` 同一条不变式：
/// 不知道就是空集，不拿旧快照去提示用户删配置。**不自动清理**：条目是用户的配置资产，
/// 由用户在区块里点 Remove（`PluginWhitelistConflictRemoval`）。
public enum WhitelistPluginConflictPolicy {

    public static func conflicts(
        entries: [WhitelistEntry],
        listState: ContainerListStore.LoadState
    ) -> [WhitelistPluginConflict] {
        // 菜单每次重算 body 都会走到这里：没有条目就不必遍历容器（常态）。
        guard !entries.isEmpty, case .loaded(let containers) = listState else { return [] }
        var owners: [ContainerID: ContainerPluginOwner] = [:]
        for container in containers {
            if let owner = container.pluginOwner { owners[container.id] = owner }
        }
        return entries.compactMap { entry in
            owners[entry.id].map { WhitelistPluginConflict(entry: entry, owner: $0) }
        }
    }
}

/// 移除一条冲突条目。与 `StaleWhitelistRemoval` 同形但**刻意不共用**（Plan R1-9：两个判定的安全含义不同，
/// 不做可注入 predicate 的公开编排）：**先刷新、再判定、判定与 remove 之间不跨 await**。
@MainActor
public enum PluginWhitelistConflictRemoval {

    /// 返回 `true` = 已发起移除；`false` = 刷新后已不是冲突（列表不权威 / 容器已变），什么都没写。
    @discardableResult
    public static func perform(
        id: ContainerID,
        containers: ContainerListStore,
        whitelist: WhitelistUIStore
    ) async -> Bool {
        await containers.refresh()

        let stillConflicting = WhitelistPluginConflictPolicy
            .conflicts(entries: whitelist.entries, listState: containers.state)
            .contains { $0.entry.id == id }
        guard stillConflicting else { return false }

        whitelist.remove(id)
        return true
    }
}
