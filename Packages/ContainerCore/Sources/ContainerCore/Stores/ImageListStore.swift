import Observation

/// 镜像删除被禁的原因。**它是给用户看的排查方向，不是内部标志位**——
/// 三档之所以要分开，是因为它们指向的动作完全不同：等一等 / 去把运行时起起来 /
/// 去看为什么 ACL 读不到 config。原先三档共用一句「配置加载失败」，
/// 会把「运行时没启动」的人送去翻配置文件。
///
/// 住在 core（不是 view 的私有 enum）：app target 没有测试 target（CLAUDE.md），
/// 判据留在 view 里就等于零覆盖。view 侧**应当**只做穷尽 `switch` 分派文案，不重算判据。
public enum ImageDeletionBlockReason: Sendable, Equatable {

    /// 首次加载还没回来。此时列表本就是空的，没有任何按钮在「悄悄变灰」。
    case stillLoading

    /// 一次成功的快照都没有过（**运行时没起来**是最常见的原因）。
    case noSnapshotYet

    /// 有快照，但 ACL 没能真实加载 config，infra 过滤退化成了 stock 名单——
    /// 旗标不可信，按 D-C fail-closed 禁删。
    case filterNotAuthoritative
}

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
    ///
    /// **派生自 `deletionBlockReason`，不再自己 switch 一遍。** 两处独立判断必然漂
    /// （CLAUDE.md：状态存两处必然漂，已经漂过一次）——尤其这两处：一处管按钮能不能按，
    /// 一处管横幅说什么，漂了就是「按钮灰着，横幅说一切正常」或者反过来。
    public var deletionEnabled: Bool { deletionBlockReason == nil }

    /// 删除被禁的**真实原因**（`nil` = 没被禁）。判据下沉到这里，是因为 view 拿不到测试：
    /// app target 没有测试 target（CLAUDE.md），在 view 里重算判据 = 零覆盖。
    /// view 侧只做穷尽 `switch` 分派文案，不重算判据
    /// （接线见 `ImagesWindowView.deletionDisabledBanner`）。
    ///
    /// 三档必须分开，因为它们把用户带向**完全不同的排查方向**：还在转圈 / 运行时没起来 /
    /// 真的是 ACL 读不到 config。原先三档共用一句「配置加载失败」，前两档是**错的**——
    /// 运行时没起来却让用户去翻配置文件。
    public var deletionBlockReason: ImageDeletionBlockReason? {
        // 复用 `lastKnownSnapshot` 而不是自己再 switch 一遍 `state`：
        // 「失败」本身不是禁删的理由——留着的旧快照才是判据来源（keep-last-snapshot
        // 的整个意义就在这），而「哪一份算最近一次已知快照」的定义已经在那个属性里。
        // 各写一遍的代价很具体：权威性判据 `isInfraFilterAuthoritative ? …` 会有两份，
        // 将来给 fail-closed 加第二个旗标时只改一处，就成了「.loaded 时禁删、
        // .failed 带旧快照时照删」——安全方向上的静默不一致。
        if case .loading = state { return .stillLoading }
        guard let snapshot = lastKnownSnapshot else { return .noSnapshotYet }
        return snapshot.isInfraFilterAuthoritative ? nil : .filterNotAuthoritative
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
