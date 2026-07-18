import Observation

/// Image 列表的 UI 状态 + 删除状态机。骨架同 `VolumeListStore`（三态 LoadState +
/// keep-last-snapshot + 单飞刷新令牌），删除流程比 volume 简单得多——镜像可重新
/// pull，不是「不可挽回」档，所以没有 typed 判据、没有 fingerprint 复核，
/// 二次确认交给 view 的 `confirmationDialog`（DAY10-DEVPLAN D-B 末段）。
@MainActor
@Observable
public final class ImageListStore {

    public enum LoadState {
        case loading
        case loaded(ImageListSnapshot)

        /// 失败带着上一次的快照——同 `VolumeListStore.LoadState.failed` 的理由。
        case failed(RuntimeError, lastKnown: ImageListSnapshot?)
    }

    /// 删除状态机。**没有 confirming/verifying**：镜像非不可挽回档，用户已经在
    /// view 的 `confirmationDialog` 里确认过了，store 只需要跑「删 → 成功/失败」。
    public enum DeletionFlow: Equatable {
        case idle
        case deleting(ImageSummary)
        case failed(ImageSummary, reason: String)
    }

    public private(set) var state: LoadState = .loading
    public private(set) var deletionFlow: DeletionFlow = .idle

    /// 当前该显示的镜像：同 `VolumeListStore.displayedVolumes` 的理由。
    public var displayedImages: [ImageSummary] {
        switch state {
        case .loading:
            []
        case .loaded(let snapshot):
            snapshot.images
        case .failed(_, let lastKnown):
            lastKnown?.images ?? []
        }
    }

    /// D-C fail-closed：删除开关只信「最近一次已知快照」的权威旗标。
    /// 没有任何快照（还在首次加载，或首次加载就失败）时**没有旗标可信**——
    /// 默认不可信，不是默认可信（跟 `sizeLabel` 的「拿不到就明说」同一条纪律）。
    public var deletionEnabled: Bool {
        switch state {
        case .loading:
            false
        case .loaded(let snapshot):
            snapshot.isInfraFilterAuthoritative
        case .failed(_, let lastKnown):
            lastKnown?.isInfraFilterAuthoritative ?? false
        }
    }

    private let client: any ContainerRuntimeClient

    /// 在途的那次刷新。单飞：新刷新一来，旧的就作废（同 `VolumeListStore`）。
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
            let snapshot = try await client.listImages()
            guard !Task.isCancelled else { return }
            state = .loaded(snapshot)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error, lastKnown: lastKnownSnapshot)
        }
    }

    private var lastKnownSnapshot: ImageListSnapshot? {
        switch state {
        case .loading:
            nil
        case .loaded(let snapshot):
            snapshot
        case .failed(_, let lastKnown):
            lastKnown
        }
    }

    // MARK: - 删除

    /// 删除镜像。**只在** `deletionEnabled && deletionFlow == .idle` 时放行：
    /// 前者是 D-C 的 fail-closed（非权威快照/无快照一律拒绝），后者防止重入
    /// （已经在删的时候，UI 按钮该被禁用，store 自己也要挡——同 `VolumeListStore`
    /// 的第二层防线纪律）。ACL 侧（★R3）还有第三道：删除前重取 infra refs 复核，
    /// 这里的 guard 只是 UX 提前拦截，不是唯一防线。
    public func deleteImage(_ image: ImageSummary) async {
        guard deletionEnabled, case .idle = deletionFlow else { return }

        deletionFlow = .deleting(image)

        do {
            try await client.deleteImage(reference: image.reference)
        } catch {
            // 跨过 await：只在这段流程仍然是「自己发起的那次」时才回写。
            guard case .deleting(let current) = deletionFlow, current == image else { return }
            deletionFlow = .failed(image, reason: String(describing: error))
            return
        }

        guard case .deleting(let current) = deletionFlow, current == image else { return }
        deletionFlow = .idle
        await refresh()
    }

    /// `.failed` 的**唯一出口**（worker 上报的死胡同：没有它，一次删除失败之后
    /// `deleteImage` 会因 flow ≠ .idle 而永远静默 no-op）。view 的错误 alert
    /// 点掉时调它。只从 `.failed` 出发——`deleting` 中途不许被打断成 idle
    /// （那会让第二次删除与在飞的第一次交错，正是 V7 要防的窗口）。
    public func dismissDeletionFailure() {
        guard case .failed = deletionFlow else { return }
        deletionFlow = .idle
    }
}
