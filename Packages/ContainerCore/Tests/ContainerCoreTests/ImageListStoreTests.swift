import Testing

@testable import ContainerCore

/// 一个**可以精确控制返回时机**的 image 运行时，只用来测单飞刷新——
/// 同 `VolumeListStoreTests` 的 `GatedVolumeRuntimeClient`。
private actor GatedImageRuntimeClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private var pendingListImages: [CheckedContinuation<ImageListSnapshot, Never>] = []

    var pendingListImagesCount: Int { pendingListImages.count }

    func listImages() async throws(RuntimeError) -> ImageListSnapshot {
        await withCheckedContinuation { continuation in
            pendingListImages.append(continuation)
        }
    }

    /// 放行第 `index` 次发起的 `listImages` 调用（0 起）。
    func completeListImages(_ index: Int, with snapshot: ImageListSnapshot) {
        pendingListImages[index].resume(returning: snapshot)
    }

    // T4 测试无消费者的方法：显式 stub（漏实现必须编译红）。
    func list() throws(RuntimeError) -> [Container] { [] }
    func start(id: ContainerID) throws(RuntimeError) {}
    func stop(id: ContainerID) throws(RuntimeError) {}
    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample { ContainerStatsSample() }
    func listVolumes() throws(RuntimeError) -> [Volume] { [] }
    func inspectVolume(named name: String) throws(RuntimeError) -> Volume? { nil }
    func deleteVolume(_ target: Volume) throws(RuntimeError) {}
    func deleteImage(reference: ImageRef) throws(RuntimeError) {}
}

@MainActor
@Suite("ImageListStore：单飞刷新 + fail-closed 删除（非权威快照禁删，D-C）")
struct ImageListStoreTests {

    static func image(_ reference: String, digest: String = "sha256:abc123") -> ImageSummary {
        ImageSummary(reference: ImageRef(reference)!, digest: digest)
    }

    private static func waitForPendingListImages(_ count: Int, on client: GatedImageRuntimeClient) async {
        for _ in 0..<10_000 {
            if await client.pendingListImagesCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 listImages 请求")
    }

    // MARK: - 基础状态

    @Test("初始是 loading，deletionFlow 是 idle，deletionEnabled 为 false（无快照 fail-closed）")
    func startsLoadingAndDisabled() {
        let store = ImageListStore(client: FakeContainerRuntimeClient(containers: []))
        guard case .loading = store.state else {
            Issue.record("期望 loading，实际 \(store.state)")
            return
        }
        #expect(store.deletionFlow == .idle)
        #expect(!store.deletionEnabled)
    }

    @Test("刷新成功（权威）→ loaded，deletionEnabled 为 true")
    func refreshLoadsAuthoritative() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        let store = ImageListStore(client: client)

        await store.refresh()

        guard case .loaded(let snapshot) = store.state else {
            Issue.record("期望 loaded，实际 \(store.state)")
            return
        }
        #expect(snapshot.images == [img])
        #expect(store.displayedImages == [img])
        #expect(store.deletionEnabled)
    }

    // MARK: - 单飞刷新

    @Test("刷新单飞：慢刷新期间再刷，只落最后一次")
    func staleRefreshDoesNotOverwriteNewer() async {
        let client = GatedImageRuntimeClient()
        let store = ImageListStore(client: client)

        let first = Task { await store.refresh() }
        await Self.waitForPendingListImages(1, on: client)

        let second = Task { await store.refresh() }
        await Self.waitForPendingListImages(2, on: client)

        let newImage = Self.image("docker.io/library/new:latest")
        let staleImage = Self.image("docker.io/library/stale:latest")

        // 后发起的先返回。
        await client.completeListImages(1, with: ImageListSnapshot(images: [newImage], isInfraFilterAuthoritative: true))
        // 先发起的后返回——它已经被取代了，不该再写回。
        await client.completeListImages(0, with: ImageListSnapshot(images: [staleImage], isInfraFilterAuthoritative: true))

        await first.value
        await second.value

        #expect(store.displayedImages == [newImage])
    }

    // MARK: - keep-last-snapshot

    @Test("刷新失败 → failed，保留上一份快照；displayedImages 与 deletionEnabled 都不清空/不翻转")
    func refreshFailureKeepsLastKnownSnapshot() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        let store = ImageListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .listImages)
        await store.refresh()

        guard case .failed(let error, let lastKnown) = store.state else {
            Issue.record("期望 failed，实际 \(store.state)")
            return
        }
        #expect(error == .runtimeUnavailable)
        #expect(lastKnown?.images == [img])
        #expect(store.displayedImages == [img])
        #expect(store.deletionEnabled)
    }

    // MARK: - D-C fail-closed：非权威 / 无快照禁删

    @Test("非权威快照 → deletionEnabled 为 false，deleteImage 是 no-op（D-C fail-closed）")
    func deletionDisabledWhenNonAuthoritative() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: false)
        let store = ImageListStore(client: client)

        await store.refresh()
        #expect(!store.deletionEnabled)

        await store.deleteImage(img)

        #expect(store.deletionFlow == .idle)
        let calls = await client.calls
        #expect(!calls.contains(.deleteImage(img.reference)))
    }

    @Test("无快照（首刷失败）→ deletionEnabled 为 false，deleteImage 是 no-op")
    func deletionDisabledWithNoSnapshot() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.runtimeUnavailable, for: .listImages)
        let store = ImageListStore(client: client)

        await store.refresh()
        #expect(!store.deletionEnabled)

        let img = Self.image("docker.io/library/busybox:latest")
        await store.deleteImage(img)

        #expect(store.deletionFlow == .idle)
        let calls = await client.calls
        #expect(!calls.contains(.deleteImage(img.reference)))
    }

    // MARK: - 删除

    @Test("权威快照下删除成功 → idle，刷新后展示列表不含该镜像")
    func deleteImageSucceeds() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        let store = ImageListStore(client: client)

        await store.refresh()
        #expect(store.deletionEnabled)

        await store.deleteImage(img)

        #expect(store.deletionFlow == .idle)
        #expect(store.displayedImages.isEmpty)

        let calls = await client.calls
        #expect(calls == [.listImages, .deleteImage(img.reference), .listImages])
    }

    @Test("delete 失败 → failed 携带 reason")
    func deleteImageFailure() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        await client.inject(.operationFailed(reason: "image in use"), for: .deleteImage)
        let store = ImageListStore(client: client)

        await store.refresh()
        await store.deleteImage(img)

        guard case .failed(let failedImage, let reason) = store.deletionFlow else {
            Issue.record("期望 failed，实际 \(store.deletionFlow)")
            return
        }
        #expect(failedImage == img)
        #expect(reason.contains("image in use"))
    }

    @Test("failed 不是死胡同：dismiss 回 idle 后可以再删（worker 上报的设计缺口）")
    func dismissFailureAllowsRetry() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        await client.inject(.operationFailed(reason: "image in use"), for: .deleteImage)
        let store = ImageListStore(client: client)

        await store.refresh()
        await store.deleteImage(img)
        guard case .failed = store.deletionFlow else {
            Issue.record("前置失败：期望 failed，实际 \(store.deletionFlow)")
            return
        }

        // 没有 dismiss 的话，这里的 deleteImage 会因 flow != .idle 而永远静默 no-op。
        store.dismissDeletionFailure()
        #expect(store.deletionFlow == .idle)

        await client.inject(nil, for: .deleteImage)
        await store.deleteImage(img)
        #expect(store.deletionFlow == .idle)
        #expect(store.displayedImages.isEmpty)
    }

    @Test("dismiss 在非 failed 态是 no-op（不许把 deleting 中途打断成 idle）")
    func dismissIsNoOpOutsideFailed() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        let store = ImageListStore(client: client)

        store.dismissDeletionFailure()
        #expect(store.deletionFlow == .idle)

        await store.refresh()
        store.dismissDeletionFailure()
        #expect(store.deletionFlow == .idle)
    }

    // MARK: - P2-A：禁删的**真实原因**（真值表）
    //
    // 每条都同时断言 reason 与 enabled 的**具体取值**。刻意不写
    // 「`deletionEnabled == (deletionBlockReason == nil)`」——`deletionEnabled` 已经是
    // 派生属性，那条断言恒真，零信息量（Plan §2 T2，Codex C10）。
    //
    // 后两条（`.failed` 携带 lastKnown 的两种权威性）此前**完全没有覆盖**：
    // 「失败但有旧快照」正是 App 日常最长待的状态，横幅文案分派全落在这两格上。

    @Test("首次加载未回（.loading）→ .stillLoading，禁删")
    func blockReasonIsStillLoadingBeforeFirstRefresh() {
        let store = ImageListStore(client: FakeContainerRuntimeClient(containers: []))

        #expect(store.deletionBlockReason == .stillLoading)
        #expect(!store.deletionEnabled)
    }

    @Test("加载成功且权威（.loaded）→ 无原因，可删")
    func blockReasonIsNilWhenLoadedAuthoritative() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        let store = ImageListStore(client: client)

        await store.refresh()

        #expect(store.deletionBlockReason == nil)
        #expect(store.deletionEnabled)
    }

    @Test("加载成功但非权威（.loaded）→ .filterNotAuthoritative，禁删")
    func blockReasonIsFilterNotAuthoritativeWhenLoaded() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: false)
        let store = ImageListStore(client: client)

        await store.refresh()

        #expect(store.deletionBlockReason == .filterNotAuthoritative)
        #expect(!store.deletionEnabled)
    }

    @Test("首刷就失败、一份快照都没有（.failed(_, nil)）→ .noSnapshotYet，禁删")
    func blockReasonIsNoSnapshotYetWhenFirstRefreshFails() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.runtimeUnavailable, for: .listImages)
        let store = ImageListStore(client: client)

        await store.refresh()

        #expect(store.deletionBlockReason == .noSnapshotYet)
        #expect(!store.deletionEnabled)
    }

    @Test("失败但留着权威旧快照（.failed(_, 权威)）→ 无原因，仍可删")
    func blockReasonIsNilWhenFailedWithAuthoritativeLastKnown() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: true)
        let store = ImageListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .listImages)
        await store.refresh()

        guard case .failed = store.state else {
            Issue.record("前置失败：期望 failed，实际 \(store.state)")
            return
        }
        #expect(store.deletionBlockReason == nil)
        #expect(store.deletionEnabled)
    }

    @Test("失败且旧快照非权威（.failed(_, 非权威)）→ .filterNotAuthoritative，禁删")
    func blockReasonIsFilterNotAuthoritativeWhenFailedWithLastKnown() async {
        let img = Self.image("docker.io/library/busybox:latest")
        let client = FakeContainerRuntimeClient(containers: [], images: [img], isInfraFilterAuthoritative: false)
        let store = ImageListStore(client: client)

        await store.refresh()
        await client.inject(.runtimeUnavailable, for: .listImages)
        await store.refresh()

        guard case .failed = store.state else {
            Issue.record("前置失败：期望 failed，实际 \(store.state)")
            return
        }
        #expect(store.deletionBlockReason == .filterNotAuthoritative)
        #expect(!store.deletionEnabled)
    }

    /// 守的是：**任何上游错误一旦到达，状态就离开 `.loading`**，落到 `.failed(_, nil)`
    /// → `.noSnapshotYet`。横幅该说的是「列表从来没加载成功过」，不是继续转圈。
    ///
    /// 它的增量在于**与 `blockReasonIsNoSnapshotYetWhenFirstRefreshFails`（注入
    /// `.runtimeUnavailable`）构成差分**：两个身份不同的错误必须落进同一格——分类只看
    /// `state` 的 case，**不嗅 `reason` 字符串**。谁哪天想给超时开小灶（「超时就继续显示
    /// loading」），**只有这条会红**（已突变验证：给 `.failed` 加一句嗅 `"timed out"` 的分支
    /// → 本条红、那条绿）。除此之外两条同烧同灭。
    ///
    /// **它守不到的（原注释宣称过，是假的）**：`listImages` 被 `XPCTimeout` 包裹这件事，
    /// 本测试**看不见**——`deletionBlockReason` 用 `case .failed(_, let lastKnown)` 把错误值丢了，
    /// 注入超时错误与注入任何别的错误对它完全不可分辨；且 `ContainerCore` 的 testTarget 依赖只有
    /// `["ContainerCore", "BoundaryScanning"]`，**不依赖 `ContainerRuntime`**，原理上够不着
    /// `XPCTimeout`。那条不变式由跨包的 `RuntimeBoundaryTests.upstreamCallsAreTimeoutBounded`
    /// 守（扫 `LiveContainerRuntimeClient` 源码，突变验证过）。
    @Test("上游超时 → 落 .noSnapshotYet，不停在 .stillLoading")
    func timeoutMovesOffStillLoading() async {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.operationFailed(reason: "XPC call timed out (5 seconds)"), for: .listImages)
        let store = ImageListStore(client: client)

        await store.refresh()

        // 刻意不加 `!= .stillLoading`：它被下面这条 `== .noSnapshotYet` 逻辑蕴含
        // （`deletionBlockReason` 是纯计算属性，两条断言之间 state 无变更），
        // 突变检出贡献实测为 0——把 `.failed(_, nil)` 改成返回 `.stillLoading`，
        // 下面这条照样红，且失败信息还更准（直接打印实际值）。意图在测试名里。
        #expect(store.deletionBlockReason == .noSnapshotYet)
        #expect(!store.deletionEnabled)
    }
}
