/// 「白名单里这条，对应的容器还在吗？」——以及**现在**还能不能删它。
///
/// ## 为什么需要它
///
/// 菜单里那排勾选框是按**容器列表**渲染的。容器被删掉之后，它在白名单里的条目
/// 就此从界面上消失——既看不见，也没法取消勾选，只能去 Finder 手改 JSON。
/// 这些条目对 supervisor 是惰性的（`enabled=false` 时连拉都不会拉），
/// 但它们会一直躺在配置里，而 `enabled=true` 的那种还会持续触发「白名单里有容器不存在」的通知。
///
/// ## ★ 两条不变式（比这个功能本身重要得多）
///
/// **1. 列表不权威时，孤儿集合必须是空集。**
///
/// `container system stop` 之后 `list()` 失败，白名单里**每一条**看起来都是孤儿。
/// 若据此在界面上提示「这些条目失效了」，用户点一下——**整份白名单蒸发**。
/// 而白名单是配置资产、是这个 App 存在的全部理由（supervisor 靠它拉容器），
/// 误报还恰恰发生在「运行时刚挂」这个本 App 唯一该活着的时刻。
///
/// 所以判定只在 `.loaded` 时成立。`.failed` 无论有没有 `lastKnown`、以及 `.loading`，
/// 一律空集——**空列表不是「容器都没了」的证据，它同样可能是「还不知道」**。
/// （同理：**自动清理绝不做**。这个洞的两种形态，一种比一种安静。）
///
/// **2. 展示时是孤儿 ≠ 按下确认那一刻还是孤儿。**
///
/// 菜单可以一直开着不动，而这期间运行时可能挂了、或那个容器被重新创建了回来。
/// 所以删除路径要**重新判定**一次（`canRemove`），而不是复用当初算出孤儿集合时的结论。
///
/// 但要说清楚它做不到什么：`canRemove` 判的是**调用那一刻手上这份 `listState`**。
/// 上游没有事件流（`XPCRoute.containerEvent` 从未接线），状态只能靠轮询——
/// 所以「相对于 runtime 当下真实状态」的原子校验在架构上不可能达成。
/// 调用方的职责是**先刷新再判定**，把窗口从「一个轮询周期」压到「一次刷新的往返」。
/// 剩下的残余窗口接受，理由是后果可恢复：删错了重新勾一次就回来，
/// 与 volume 那种「加密后不可恢复」不同级。
public enum WhitelistOrphanPolicy {

    /// 展示侧：哪些条目该出现在「失效条目」区里。
    public static func orphans(
        entries: [WhitelistEntry],
        listState: ContainerListStore.LoadState
    ) -> [WhitelistEntry] {
        guard let known = authoritativeIDs(listState) else { return [] }

        return entries.filter { !known.contains($0.id) }
    }

    /// 删除侧：**确认之后**再判一次。
    ///
    /// 与 `orphans` 共用同一个判据——两处各写一份必然漂，
    /// 而漂的方向大概率是「展示更保守、删除更宽松」，正好是最坏的那种组合。
    public static func canRemove(
        id: ContainerID,
        entries: [WhitelistEntry],
        listState: ContainerListStore.LoadState
    ) -> Bool {
        orphans(entries: entries, listState: listState).contains { $0.id == id }
    }

    /// 「此刻我能不能信这份容器列表？」——不能则 `nil`，而不是空集合。
    ///
    /// 返回 `Optional` 不是风格选择：空集合会被下游当成「一个容器都没有」，
    /// 于是**每条白名单都成了孤儿**。「不知道」和「知道是空的」必须是两个不同的值。
    private static func authoritativeIDs(
        _ state: ContainerListStore.LoadState
    ) -> Set<ContainerID>? {
        switch state {
        case .loaded(let containers):
            Set(containers.map(\.id))
        case .loading, .failed:
            nil
        }
    }
}

/// 「移除一条失效的白名单条目」的完整编排。**它住在 core 是因为它承载不变式 2**——
/// 放进 view 的按钮回调里就等于零测试（app target 没有测试 target）。
@MainActor
public enum StaleWhitelistRemoval {

    /// 返回 `true` = 已发起移除；`false` = 状态已变，什么都没写。
    ///
    /// ## 三步的顺序不能换
    ///
    /// 1. **先刷新**。展示时算出的「孤儿」身份来自上一次轮询的快照，可能已经过期
    ///    ——运行时挂了，或那个容器被重新创建了回来。菜单可以一直开着，这个窗口能有一整个轮询周期。
    /// 2. **再判定**。用刚取回的 `state`，不是当初那份。
    /// 3. **判定与 `remove` 之间不跨 `await`**。中间只要有一个挂起点，MainActor 就可能重入
    ///    （本仓库栽过三次），于是「判定通过」和「执行删除」之间又开出一道缝。
    ///
    /// ## 说清楚它做不到什么
    ///
    /// 这**不是**相对于 runtime 当下状态的原子校验，那在架构上做不到：上游没有事件流
    /// （`XPCRoute.containerEvent` 从未接线），也没有条件写。本函数能做的是把窗口
    /// 从「一个轮询周期」压到「一次刷新的往返」。
    /// 剩下的残余风险接受，依据是**后果可恢复**——万一删错，重新勾一次就回来了。
    @discardableResult
    public static func perform(
        id: ContainerID,
        containers: ContainerListStore,
        whitelist: WhitelistUIStore
    ) async -> Bool {
        await containers.refresh()

        guard
            WhitelistOrphanPolicy.canRemove(
                id: id,
                entries: whitelist.entries,
                listState: containers.state
            )
        else { return false }

        whitelist.remove(id)
        return true
    }
}
