import Testing

@testable import ContainerCore

/// 一个**可以精确控制返回时机**的 image 运行时，只用来测单飞刷新——
/// 同 `VolumeListStoreTests` 的 `GatedVolumeRuntimeClient`。
private actor GatedImageRuntimeClient: ContainerRuntimeClient {

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
}
