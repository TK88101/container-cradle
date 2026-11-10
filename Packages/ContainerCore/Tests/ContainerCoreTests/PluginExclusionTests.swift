import Foundation
import Testing

@testable import ContainerCore

/// Day 29：带 `com.apple.container.plugin` 标签的容器归插件管，本 App 不碰它的生命周期
/// （Plan 2026-11-10-plugin-exclusion）。
@Suite("Plugin 容器排除")
struct PluginExclusionTests {

    private let g = RuntimeGeneration(pid: 1, startTime: 1)

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    private func container(
        _ raw: String,
        _ state: ContainerState = .stopped,
        owner: ContainerPluginOwner? = nil
    ) -> Container {
        Container(id: id(raw), image: ImageRef("busybox:1")!, state: state, environment: [], pluginOwner: owner)
    }

    private let builder = ContainerPluginOwner(rawValue: "builder")

    // MARK: - domain

    @Test("只有精确的 machine / cluster 从列表隐藏；builder、未知值、空串都显示（R1-6）")
    func hiddenTruthTable() {
        #expect(ContainerPluginOwner.machine.isHiddenFromContainerList)
        #expect(ContainerPluginOwner.cluster.isHiddenFromContainerList)
        #expect(!builder.isHiddenFromContainerList)
        #expect(!ContainerPluginOwner(rawValue: "").isHiddenFromContainerList)
        #expect(!ContainerPluginOwner(rawValue: "Cluster").isHiddenFromContainerList)
        #expect(!ContainerPluginOwner(rawValue: "cluster-x").isHiddenFromContainerList)
    }

    @Test("Container 默认不归插件管")
    func defaultOwnerIsNil() {
        let plain = Container(id: id("a"), image: ImageRef("busybox:1")!, state: .stopped, environment: [])
        #expect(plain.pluginOwner == nil)
    }

    // MARK: - 列表展示

    @Test("菜单列表隐藏 machine / cluster，保留普通容器与 builder，顺序不变")
    func visibleInMenu() {
        let all = [
            container("a"),
            container("m", owner: .machine),
            container("buildkit", owner: builder),
            container("n", owner: .cluster),
            container("b"),
        ]
        #expect(ContainerListPresentation.visibleInMenu(all).map(\.id.rawValue) == ["a", "buildkit", "b"])
    }

    @Test("isPluginManaged：任何 owner（含空串）都算插件管理")
    func isPluginManaged() {
        #expect(!container("a").isPluginManaged)
        #expect(container("buildkit", owner: builder).isPluginManaged)
        #expect(container("x", owner: ContainerPluginOwner(rawValue: "")).isPluginManaged)
    }

    @Test("owner 展示名：单行化、trim、截断；空 / 全空白 → nil（走 generic 文案，R1-10）")
    func ownerDisplayName() {
        #expect(ContainerPluginOwnerPresentation.displayName(builder) == "builder")
        #expect(ContainerPluginOwnerPresentation.displayName(ContainerPluginOwner(rawValue: "")) == nil)
        #expect(ContainerPluginOwnerPresentation.displayName(ContainerPluginOwner(rawValue: " \n\t ")) == nil)
        #expect(ContainerPluginOwnerPresentation.displayName(ContainerPluginOwner(rawValue: "a\nb\r\nc")) == "a b c")
        let long = String(repeating: "x", count: 40)
        let shown = ContainerPluginOwnerPresentation.displayName(ContainerPluginOwner(rawValue: long))
        #expect(shown == String(repeating: "x", count: 31) + "…")
        let exact = String(repeating: "y", count: 32)
        #expect(ContainerPluginOwnerPresentation.displayName(ContainerPluginOwner(rawValue: exact)) == exact)
    }

    @Test("行内说明：有名字带名字，没名字用 generic", arguments: ["en", "zh-Hans", "zh-Hant", "ja"])
    func managedByText(lang: String) {
        let locale = Locale(identifier: lang)
        let named = ContainerPluginOwnerPresentation.managedByText(builder, locale: locale)
        let generic = ContainerPluginOwnerPresentation.managedByText(ContainerPluginOwner(rawValue: ""), locale: locale)
        #expect(named.contains("builder"))
        #expect(!generic.isEmpty)
        #expect(named != generic)
    }

    @Test("行内说明非英文不是英文回退", arguments: ["zh-Hans", "zh-Hant", "ja"])
    func managedByTextTranslated(lang: String) {
        let en = ContainerPluginOwnerPresentation.managedByText(builder, locale: Locale(identifier: "en"))
        #expect(ContainerPluginOwnerPresentation.managedByText(builder, locale: Locale(identifier: lang)) != en)
    }

    // MARK: - 分类

    @Test("pluginManaged → permanent（重试无意义，绝不进 transient / 熔断）")
    func classification() {
        #expect(FailureKind(from: .pluginManaged(id("buildkit"), owner: builder)) == .permanent)
    }

    @Test("错误详情四语都有，且不是英文原句的回退", arguments: ["zh-Hans", "zh-Hant", "ja"])
    func errorDetailLocalized(lang: String) {
        let error = RuntimeError.pluginManaged(id("buildkit"), owner: builder)
        let en = RuntimeErrorPresentation.detail(error, locale: Locale(identifier: "en"))
        let other = RuntimeErrorPresentation.detail(error, locale: Locale(identifier: lang))
        #expect(en.contains("buildkit"))
        #expect(other.contains("buildkit"))
        #expect(other != en)
    }

    // MARK: - Fake 与 Live 同语义

    @Test("Fake：plugin 容器 start / stop 抛 pluginManaged，状态不变")
    func fakeRefuses() async throws {
        let client = FakeContainerRuntimeClient(containers: [container("buildkit", .running, owner: builder)])
        await #expect(throws: RuntimeError.pluginManaged(id("buildkit"), owner: builder)) {
            try await client.start(id: id("buildkit"))
        }
        await #expect(throws: RuntimeError.pluginManaged(id("buildkit"), owner: builder)) {
            try await client.stop(id: id("buildkit"))
        }
        #expect(try await client.list().first?.state == .running)
    }

    @Test("Fake：普通容器状态迁移保留 owner 字段")
    func fakeTransitionKeepsOwner() async throws {
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        try await client.start(id: id("a"))
        let after = try await client.list().first
        #expect(after?.state == .running)
        #expect(after?.pluginOwner == nil)
    }

    // MARK: - engine

    @Test("白名单 [plugin, 普通] → 普通被拉、plugin 跳过、整体 success、记一次 skip、不记 startFailed")
    func engineSkipsPlugin() async throws {
        let client = FakeContainerRuntimeClient(containers: [
            container("buildkit", owner: builder), container("a"),
        ])
        let log = SpySupervisorLog()
        let engine = WhitelistReconcileEngine(
            client: client,
            whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("buildkit")), WhitelistEntry(id: id("a"))]),
            log: log
        )

        #expect(await engine.reconcile(generation: g) == .success)
        #expect(try await client.list().contains { $0.id == id("a") && $0.state == .running })
        #expect(log.entries.filter { $0 == .pluginEntrySkipped(id("buildkit"), builder, g) }.count == 1)
        #expect(!log.entries.contains { if case .containerStartFailed = $0 { true } else { false } })
    }

    @Test("白名单只有 plugin → success（不退避、不熔断）")
    func engineOnlyPlugin() async {
        let client = FakeContainerRuntimeClient(containers: [container("buildkit", owner: builder)])
        let engine = WhitelistReconcileEngine(
            client: client, whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("buildkit"))])
        )
        #expect(await engine.reconcile(generation: g) == .success)
    }

    @Test("[plugin, 真 transient] → transient 仍主导（R1-7）")
    func engineTransientStillDominates() async {
        let client = FakeContainerRuntimeClient(containers: [
            container("buildkit", owner: builder), container("a"),
        ])
        await client.inject(.operationFailed(reason: "boom"), for: .start)
        let engine = WhitelistReconcileEngine(
            client: client,
            whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("buildkit")), WhitelistEntry(id: id("a"))])
        )
        #expect(await engine.reconcile(generation: g) == .failure(.transient))
    }

    // MARK: - 冲突区块判定

    @Test(".loaded：白名单里指向 plugin 容器的条目（不论 enabled）是冲突")
    func conflictsWhenLoaded() {
        let entries = [
            WhitelistEntry(id: id("a")),
            WhitelistEntry(id: id("buildkit"), enabled: false),
            WhitelistEntry(id: id("n")),
            WhitelistEntry(id: id("gone")),
        ]
        let state = ContainerListStore.LoadState.loaded([
            container("a"), container("buildkit", owner: builder), container("n", owner: .cluster),
        ])
        let conflicts = WhitelistPluginConflictPolicy.conflicts(entries: entries, listState: state)
        #expect(conflicts == [
            WhitelistPluginConflict(entry: entries[1], owner: builder),
            WhitelistPluginConflict(entry: entries[2], owner: .cluster),
        ])
    }

    @Test("列表不权威（loading / failed 带旧数据）→ 冲突为空集")
    func conflictsEmptyWhenNotAuthoritative() {
        let entries = [WhitelistEntry(id: id("buildkit"))]
        let lastKnown = [container("buildkit", owner: builder)]
        #expect(WhitelistPluginConflictPolicy.conflicts(entries: entries, listState: .loading).isEmpty)
        #expect(WhitelistPluginConflictPolicy.conflicts(
            entries: entries, listState: .failed(.runtimeUnavailable, lastKnown: lastKnown)
        ).isEmpty)
    }

    @Test("F10 回归钉：被菜单隐藏的 cluster 节点的白名单条目不是孤儿")
    func hiddenClusterEntryIsNotOrphan() {
        let entries = [WhitelistEntry(id: id("n"))]
        let state = ContainerListStore.LoadState.loaded([container("n", owner: .cluster)])
        #expect(WhitelistOrphanPolicy.orphans(entries: entries, listState: state).isEmpty)
    }

    // MARK: - 有效受管集合

    @Test("pluginIDs / effective 真值表；known 为空 → 不减（R2-4 的保守方向）")
    func managedSet() {
        let known = [container("a"), container("buildkit", owner: builder), container("m", owner: .machine)]
        #expect(ManagedContainerSet.pluginIDs(in: known) == [id("buildkit"), id("m")])
        #expect(ManagedContainerSet.effective(enabled: [id("a"), id("buildkit")], known: known) == [id("a")])
        #expect(ManagedContainerSet.effective(enabled: [id("a"), id("buildkit")], known: []) == [id("a"), id("buildkit")])
        #expect(ManagedContainerSet.effective(enabled: [], known: known).isEmpty)
    }

    // MARK: - 菜单动作

    @Test("restart plugin 容器：stop 段就被拒（restartStopFailed），状态未变、没有 start 调用")
    @MainActor
    func restartRefusedBeforeStop() async throws {
        let client = FakeContainerRuntimeClient(containers: [container("buildkit", .running, owner: builder)])
        let store = ContainerActionStore(client: client, onActionCompleted: {})

        await store.restart(id: id("buildkit"))

        #expect(store.error(for: id("buildkit")) == .restartStopFailed(.pluginManaged(id("buildkit"), owner: builder)))
        #expect(await client.calls == [.stop(id("buildkit"))])
        #expect(try await client.list().first?.state == .running)
    }
}
