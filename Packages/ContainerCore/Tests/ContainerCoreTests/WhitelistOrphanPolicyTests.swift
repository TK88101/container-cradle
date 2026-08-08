import Testing

@testable import ContainerCore

/// 孤儿白名单条目的判定。**这里守的是两条不变式，不是一个功能。**
///
/// 白名单是配置资产，不是缓存。误判一条为「孤儿」并让用户点掉它，
/// 后果是 supervisor 从此不再拉那个容器——而这正是本 App 存在的全部理由。
@Suite("白名单孤儿条目：展示侧与删除侧的两条不变式")
struct WhitelistOrphanPolicyTests {

    private let alive = ContainerID("alive")!
    private let ghost = ContainerID("ghost")!

    private func container(_ id: ContainerID) -> Container {
        Container(id: id, image: ImageRef("alpine:latest")!, state: .running, environment: [])
    }

    private var entries: [WhitelistEntry] {
        [WhitelistEntry(id: alive, enabled: true), WhitelistEntry(id: ghost, enabled: false)]
    }

    // MARK: - 不变式 1：展示侧

    @Test("列表权威时，白名单里没有对应容器的条目算孤儿")
    func orphanWhenLoadedAndMissing() {
        let orphans = WhitelistOrphanPolicy.orphans(
            entries: entries,
            listState: .loaded([container(alive)])
        )

        #expect(orphans.map(\.id) == [ghost])
    }

    @Test("容器还在列表里 → 不是孤儿")
    func notOrphanWhenPresent() {
        let orphans = WhitelistOrphanPolicy.orphans(
            entries: entries,
            listState: .loaded([container(alive), container(ghost)])
        )

        #expect(orphans.isEmpty)
    }

    /// ★ 运行时挂掉时 `list()` 失败，白名单里**每一条**看起来都是孤儿。
    /// 若据此提示「这些失效了」，用户一点 → 整份白名单蒸发，
    /// 而且恰恰发生在这个 App 唯一该活着的时刻。
    @Test("★ 刷新失败（带上一次快照）→ 空集，绝不提示删除")
    func noOrphansWhenFailedWithLastKnown() {
        let orphans = WhitelistOrphanPolicy.orphans(
            entries: entries,
            listState: .failed(.operationFailed(reason: "runtime down"), lastKnown: [container(alive)])
        )

        #expect(orphans.isEmpty)
    }

    /// 无 lastKnown 那一档更危险：**所有**条目都「不在列表里」。
    @Test("★ 刷新失败且无快照 → 空集")
    func noOrphansWhenFailedWithoutLastKnown() {
        let orphans = WhitelistOrphanPolicy.orphans(
            entries: entries,
            listState: .failed(.operationFailed(reason: "cold start"), lastKnown: [])
        )

        #expect(orphans.isEmpty)
    }

    @Test("★ 首次加载中 → 空集（空列表不是『容器都没了』的证据）")
    func noOrphansWhileLoading() {
        let orphans = WhitelistOrphanPolicy.orphans(entries: entries, listState: .loading)

        #expect(orphans.isEmpty)
    }

    /// 孤儿与 `enabled` 无关：`enabled=true` 的孤儿正是已有系统通知在报的那种
    /// （「白名单里有容器不存在」），它同样需要一个移除入口。
    @Test("enabled=true 的孤儿也算孤儿")
    func orphanRegardlessOfEnabled() {
        let enabledGhost = [WhitelistEntry(id: ghost, enabled: true)]

        let orphans = WhitelistOrphanPolicy.orphans(entries: enabledGhost, listState: .loaded([]))

        #expect(orphans.map(\.id) == [ghost])
    }

    // MARK: - 不变式 2：删除侧
    //
    // 展示时是孤儿，不代表**按下确认那一刻**还是孤儿。菜单可以一直开着，
    // 而这期间运行时可能挂了、或那个容器被重新创建了回来。

    @Test("★ 判定时列表已不权威 → 拒绝删除")
    func cannotRemoveWhenListNotAuthoritative() {
        #expect(
            !WhitelistOrphanPolicy.canRemove(
                id: ghost,
                entries: entries,
                listState: .failed(.operationFailed(reason: "runtime down"), lastKnown: [])
            )
        )
    }

    @Test("★ 容器在确认前被重新创建 → 拒绝删除")
    func cannotRemoveWhenContainerCameBack() {
        #expect(
            !WhitelistOrphanPolicy.canRemove(
                id: ghost,
                entries: entries,
                listState: .loaded([container(alive), container(ghost)])
            )
        )
    }

    @Test("仍是孤儿 → 允许删除")
    func canRemoveWhenStillOrphan() {
        #expect(
            WhitelistOrphanPolicy.canRemove(
                id: ghost,
                entries: entries,
                listState: .loaded([container(alive)])
            )
        )
    }

    @Test("白名单里压根没有这条 → 拒绝（没什么可删的）")
    func cannotRemoveUnknownEntry() {
        #expect(
            !WhitelistOrphanPolicy.canRemove(
                id: ContainerID("never-added")!,
                entries: entries,
                listState: .loaded([container(alive)])
            )
        )
    }
}
