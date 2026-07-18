import Observation

/// Volume 列表的 UI 状态 + 删除状态机。骨架抄 `ContainerListStore`
/// （三态 LoadState + keep-last-snapshot + 单飞刷新令牌）；删除流程是本 store 独有的部分。
///
/// ## 为什么删除判据也住这里而不是 view
///
/// app target 没有测试 target（CLAUDE.md 已踩过的坑）。删 volume 是 V1 顶格风险
/// （卷里可能是加密后不可恢复的数据），判据必须可测——放在 view 里等于零测试。
@MainActor
@Observable
public final class VolumeListStore {

    public enum LoadState {
        case loading
        case loaded([Volume])

        /// 失败带着上一次的快照——同 `ContainerListStore.LoadState.failed` 的理由：
        /// 运行时挂掉不该被误读成「卷被删了」。
        case failed(RuntimeError, lastKnown: [Volume])
    }

    /// 删除状态机（DAY10-DEVPLAN D-B）。
    ///
    /// `verifying` / `deleting` 是 in-flight 的两态：`beginDeletion` / `cancelDeletion`
    /// 的守卫只认 idle/failed/targetChanged，这两态外部动不了——这是「跨过 await
    /// 重新证明世界没变」在人类时间尺度（确认框开着的几十秒）的同构。
    public enum DeletionFlow: Equatable {
        case idle
        case confirming(target: Volume)
        case verifying(target: Volume)
        case deleting(target: Volume)
        case failed(target: Volume, reason: String)
        case targetChanged(target: Volume)
    }

    public private(set) var state: LoadState = .loading
    public private(set) var deletionFlow: DeletionFlow = .idle

    /// 当前该显示的卷：同 `ContainerListStore.displayedContainers` 的理由。
    public var displayedVolumes: [Volume] {
        switch state {
        case .loading:
            []
        case .loaded(let volumes):
            volumes
        case .failed(_, let lastKnown):
            lastKnown
        }
    }

    private let client: any ContainerRuntimeClient

    /// 在途的那次刷新。单飞：新刷新一来，旧的就作废（同 `ContainerListStore`）。
    private var inFlight: Task<Void, Never>?

    public init(client: any ContainerRuntimeClient) {
        self.client = client
    }

    // MARK: - 刷新（单飞令牌，理由见 `ContainerListStore.refresh`）

    public func refresh() async {
        inFlight?.cancel()

        let task = Task { await self.load() }

        inFlight = task
        await task.value
    }

    private func load() async {
        do {
            let volumes = try await client.listVolumes()
            guard !Task.isCancelled else { return }
            state = .loaded(volumes)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error, lastKnown: lastKnownVolumes)
        }
    }

    private var lastKnownVolumes: [Volume] {
        switch state {
        case .loading:
            []
        case .loaded(let volumes):
            volumes
        case .failed(_, let lastKnown):
            lastKnown
        }
    }

    // MARK: - 删除状态机

    /// 进入确认态。**仅** idle/failed/targetChanged 时放行——verifying/deleting 是
    /// in-flight 的两态，不许中途换靶；confirming 本身也不在放行名单里，
    /// 所以「确认框开着时点了另一个卷」也不会静默换靶，得先 cancel 再重新 begin。
    public func beginDeletion(of volume: Volume) {
        switch deletionFlow {
        case .idle, .failed, .targetChanged:
            deletionFlow = .confirming(target: volume)
        case .confirming, .verifying, .deleting:
            break
        }
    }

    /// 取消确认。**仅** confirming/failed/targetChanged 时放行——in-flight
    /// （verifying/deleting）期间 UI 按钮该被禁用，但 store 自己也要挡：
    /// 这不是洁癖，是防线的第二层（万一 UI 没禁用成功）。
    public func cancelDeletion() {
        switch deletionFlow {
        case .confirming, .failed, .targetChanged:
            deletionFlow = .idle
        case .idle, .verifying, .deleting:
            break
        }
    }

    /// 输入是否足以放行删除。只在 confirming 态有意义——其余态恒 false
    /// （没有 in-flight 的 target 可比对）。
    public func canConfirm(typed: String) -> Bool {
        guard case .confirming(let target) = deletionFlow else { return false }
        return TypedConfirmation.canConfirm(typed: typed, expected: target.name)
    }

    /// 确认删除。★R1/★R2/★R3（DAY10-DEVPLAN）：typed 判据通过后，真正 delete 前
    /// 必须用 identity-only 的 `inspectVolume` 复核 fingerprint——这是「确认框开着的
    /// 几十秒里，同名卷被外部删除重建」这个 TOCTOU 的防线。**不走 `listVolumes()`**：
    /// 它带 usage enrichment，会把复核窗口从 ms 级撑成秒/分钟级。
    public func confirmDeletion(typed: String) async {
        guard case .confirming(let target) = deletionFlow, canConfirm(typed: typed) else { return }

        deletionFlow = .verifying(target: target)

        let inspected: Volume?
        do {
            inspected = try await client.inspectVolume(named: target.name)
        } catch {
            // 跨过 await：只在这段流程仍然是「自己发起的那次」时才回写。
            guard case .verifying(let current) = deletionFlow, current == target else { return }
            deletionFlow = .failed(target: target, reason: String(describing: error))
            return
        }

        guard case .verifying(let current) = deletionFlow, current == target else { return }

        // nil（已消失）或 fingerprint 不再匹配（同名重建）→ 中止，绝不删。
        guard let inspected, inspected.matchesIdentity(of: target) else {
            deletionFlow = .targetChanged(target: target)
            await refresh()
            return
        }

        deletionFlow = .deleting(target: target)

        do {
            try await client.deleteVolume(target)
        } catch {
            guard case .deleting(let current) = deletionFlow, current == target else { return }
            deletionFlow = .failed(target: target, reason: String(describing: error))
            return
        }

        guard case .deleting(let current) = deletionFlow, current == target else { return }
        deletionFlow = .idle
        await refresh()
    }
}
