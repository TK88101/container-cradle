import ContainerCore
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerRuntime

/// M5：live client 的 volume / image 面。R7 的 **ACL 最后防线**（★R3）与 usage enrichment
/// 的限流 / 预算 / 闭门（★R1/★R4/★R5）都在这里被钉死——这些是四轮 codex 裁决换来的形状，
/// 别在重构里把它们「顺手简化」掉。
struct LiveContainerRuntimeClientVolumeImageTests {

    private static let created = Date(timeIntervalSince1970: 1_752_000_000)

    private func makeConfig(
        name: String = "data",
        created: Date = Self.created,
        source: String = "/vols/data/volume.img",
        sizeInBytes: UInt64? = 549_755_813_888
    ) -> VolumeConfiguration {
        VolumeConfiguration(
            name: name,
            source: source,
            creationDate: created,
            sizeInBytes: sizeInBytes
        )
    }

    private func makeDescription(
        reference: String = "docker.io/library/busybox:latest",
        digest: String = "sha256:0123456789abcdef0123456789abcdef"
    ) -> ImageDescription {
        ImageDescription(
            reference: reference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: digest,
                size: 0
            )
        )
    }

    private func makeTarget(
        name: String = "data",
        created: Date = Self.created,
        source: String = "/vols/data/volume.img",
        max: UInt64? = 549_755_813_888,
        used: UInt64? = 70_078_464
    ) -> Volume {
        Volume(name: name, creationDate: created, source: source, sizeMaxBytes: max, usedBytes: used)
    }

    private func makeClient(
        upstream: FakeUpstreamClient,
        prober: FakeRuntimeProber = .up,
        timeout: Duration = .seconds(5),
        usageBudget: Duration = .seconds(8)
    ) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: prober,
            timeout: timeout,
            usageBudget: usageBudget
        )
    }

    // MARK: - listVolumes

    @Test("listVolumes：全字段映射（含 source）+ usage 拼接")
    func listVolumesMapsEverything() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([makeConfig()])
        await fake.setUsage("data", bytes: 70_078_464)
        let client = makeClient(upstream: fake)

        let volumes = try await client.listVolumes()
        let volume = try #require(volumes.first)
        #expect(volume.name == "data")
        #expect(volume.source == "/vols/data/volume.img")
        #expect(volume.creationDate == Self.created)
        #expect(volume.sizeMaxBytes == 549_755_813_888)
        #expect(volume.usedBytes == 70_078_464)
    }

    @Test("fail-soft：单卷 usage 失败 → 该卷 nil，列表照常成活")
    func usageFailureIsSoft() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([
            makeConfig(name: "a", source: "/vols/a"),
            makeConfig(name: "b", source: "/vols/b"),
        ])
        await fake.setUsage("a", bytes: 1)
        await fake.setUsageFails("b")
        let client = makeClient(upstream: fake)

        let volumes = try await client.listVolumes()
        #expect(volumes.count == 2)
        #expect(volumes.first(where: { $0.name == "a" })?.usedBytes == 1)
        #expect(volumes.first(where: { $0.name == "b" })?.usedBytes == nil)
    }

    @Test("★R1 限流 + ★R4 no-wait：8 卷全挂死也只开 4 个口子，预算到点即返回")
    func capAndNoWaitUnderHangs() async throws {
        let fake = FakeUpstreamClient()
        let names = (0..<8).map { "vol\($0)" }
        await fake.setVolumes(names.map { makeConfig(name: $0, source: "/vols/\($0)") })
        for name in names { await fake.setUsageGated(name) }

        // per-call timeout 拉到 60s：这条测的是**预算**在管事，不是 per-call 超时在兜底。
        // 实现若拿 task group 当预算（★ 血训），这一行永不返回 → 测试冻住即失败。
        let client = makeClient(upstream: fake, timeout: .seconds(60), usageBudget: .milliseconds(150))

        let volumes = try await client.listVolumes()
        #expect(volumes.count == 8)
        #expect(volumes.allSatisfy { $0.usedBytes == nil })
        #expect(await fake.usagePeakConcurrency <= 4)
        #expect(await fake.usageStartedCount == 4)
    }

    @Test("★R5 闭门：预算到点后，在飞调用回来也不再启动新调用")
    func budgetClosesTheGate() async throws {
        let fake = FakeUpstreamClient()
        let names = (0..<6).map { "vol\($0)" }
        await fake.setVolumes(names.map { makeConfig(name: $0, source: "/vols/\($0)") })
        for name in names { await fake.setUsageGated(name) }
        let client = makeClient(upstream: fake, timeout: .seconds(60), usageBudget: .milliseconds(150))

        _ = try await client.listVolumes()
        #expect(await fake.usageStartedCount == 4)

        // 放行一个在飞的调用。闸若没关，调度器会立刻去取第 5 卷。
        #expect(await fake.releaseGatedUsage("vol0", bytes: 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.usageStartedCount == 4)
    }

    @Test("全部做完早于预算 → 立刻交卷，不干等预算")
    func finishesEarlyWhenAllDone() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([makeConfig()])
        await fake.setUsage("data", bytes: 42)
        let client = makeClient(upstream: fake, usageBudget: .seconds(60))

        let start = ContinuousClock.now
        let volumes = try await client.listVolumes()
        #expect(volumes.first?.usedBytes == 42)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    // MARK: - inspectVolume（★R2 identity-only）

    @Test("★R2 inspectVolume：identity-only——零 usage 调用，usedBytes 恒 nil")
    func inspectVolumeIsIdentityOnly() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([makeConfig()])
        await fake.setUsage("data", bytes: 70_078_464)  // 即便配置了 usage 也不许去取
        let client = makeClient(upstream: fake)

        let volume = try #require(try await client.inspectVolume(named: "data"))
        #expect(volume.name == "data")
        #expect(volume.usedBytes == nil)

        let calls = await fake.calls
        #expect(!calls.contains(.volumeUsedBytes("data")))
    }

    @Test("inspectVolume：不存在 → nil（不嗅 not-found 错误文本）")
    func inspectVolumeMissingIsNil() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([makeConfig()])
        let client = makeClient(upstream: fake)
        #expect(try await client.inspectVolume(named: "ghost") == nil)
    }

    // MARK: - deleteVolume（★R3 ACL 最后防线）

    @Test("deleteVolume：identity 匹配 → 真删（usedBytes 漂了不算变化）")
    func deleteVolumeHappyPath() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([makeConfig()])
        let client = makeClient(upstream: fake)

        try await client.deleteVolume(makeTarget(used: 999_999))  // 用量不同 ≠ 换了卷
        #expect(await fake.calls.contains(.deleteVolume("data")))
    }

    @Test("★R3 陈旧 target（同名重建）→ 拒绝，删除路由零调用——绕过 store 直调也删不错")
    func deleteVolumeRejectsStaleTarget() async throws {
        let fake = FakeUpstreamClient()
        await fake.setVolumes([
            makeConfig(created: Date(timeIntervalSince1970: 1_752_000_999))  // 重建后的新卷
        ])
        let client = makeClient(upstream: fake)

        await #expect(throws: RuntimeError.self) {
            try await client.deleteVolume(self.makeTarget())  // 拿着旧 fingerprint
        }
        let calls = await fake.calls
        #expect(!calls.contains(.deleteVolume("data")))
    }

    @Test("★R3 卷已消失 → 拒绝，删除路由零调用")
    func deleteVolumeMissingTarget() async throws {
        let fake = FakeUpstreamClient()
        let client = makeClient(upstream: fake)

        await #expect(throws: RuntimeError.self) {
            try await client.deleteVolume(self.makeTarget())
        }
        let calls = await fake.calls
        #expect(!calls.contains(.deleteVolume("data")))
    }

    // MARK: - listImages（D-C：infra 过滤在 ACL 内完成）

    @Test("listImages：infra 引用被过滤，domain 看不见；权威旗标透传")
    func listImagesFiltersInfra() async throws {
        let fake = FakeUpstreamClient()
        await fake.setImages([
            makeDescription(reference: "ghcr.io/apple/containerization/vminit:0.35.0"),
            makeDescription(reference: "docker.io/library/busybox:latest"),
        ])
        await fake.setLoadedInfraRefs(["ghcr.io/apple/containerization/vminit:0.35.0"])
        let client = makeClient(upstream: fake)

        let snapshot = try await client.listImages()
        #expect(snapshot.isInfraFilterAuthoritative)
        #expect(snapshot.images.map(\.reference.rawValue) == ["docker.io/library/busybox:latest"])
    }

    @Test("★D-C config 加载失败 → stock 过滤（展示降级）+ 非权威旗标（删除禁用的数据源）")
    func listImagesFallsBackToStock() async throws {
        let fake = FakeUpstreamClient()
        await fake.setImages([
            makeDescription(reference: "custom.registry/vminit:x"),
            makeDescription(reference: "docker.io/library/busybox:latest"),
        ])
        await fake.setLoadedInfraFails()
        await fake.setStockInfraRefs(["custom.registry/vminit:x"])
        let client = makeClient(upstream: fake)

        let snapshot = try await client.listImages()
        #expect(!snapshot.isInfraFilterAuthoritative)
        #expect(snapshot.images.map(\.reference.rawValue) == ["docker.io/library/busybox:latest"])
    }

    @Test("ImageMapper 失败关闭：空 reference → 整个 listImages 抛错，不静默丢镜像")
    func unmappableImageFailsClosed() async throws {
        let fake = FakeUpstreamClient()
        await fake.setImages([makeDescription(reference: "   ")])
        await fake.setLoadedInfraRefs([])
        let client = makeClient(upstream: fake)

        await #expect(throws: RuntimeError.self) { _ = try await client.listImages() }
    }

    // MARK: - deleteImage（★R3 删除时重新确认）

    @Test("★R3 deleteImage：非权威 → 拒绝（fail-closed），删除路由零调用")
    func deleteImageRefusesWhenNotAuthoritative() async throws {
        let fake = FakeUpstreamClient()
        await fake.setImages([makeDescription()])
        await fake.setLoadedInfraFails()
        await fake.setStockInfraRefs([])
        let client = makeClient(upstream: fake)

        await #expect(throws: RuntimeError.self) {
            try await client.deleteImage(reference: ImageRef("docker.io/library/busybox:latest")!)
        }
        let calls = await fake.calls
        #expect(!calls.contains(.deleteImage("docker.io/library/busybox:latest")))
    }

    @Test("★R3 deleteImage：命中 infra → 拒绝——旧快照 + config 变更的窗口也删不掉系统镜像")
    func deleteImageRefusesInfraHit() async throws {
        let fake = FakeUpstreamClient()
        await fake.setImages([makeDescription(reference: "ghcr.io/apple/containerization/vminit:0.35.0")])
        await fake.setLoadedInfraRefs(["ghcr.io/apple/containerization/vminit:0.35.0"])
        let client = makeClient(upstream: fake)

        await #expect(throws: RuntimeError.self) {
            try await client.deleteImage(reference: ImageRef("ghcr.io/apple/containerization/vminit:0.35.0")!)
        }
        let calls = await fake.calls
        #expect(!calls.contains(.deleteImage("ghcr.io/apple/containerization/vminit:0.35.0")))
    }

    @Test("deleteImage：权威且非 infra → 真删")
    func deleteImageHappyPath() async throws {
        let fake = FakeUpstreamClient()
        await fake.setImages([makeDescription()])
        await fake.setLoadedInfraRefs(["ghcr.io/apple/containerization/vminit:0.35.0"])
        let client = makeClient(upstream: fake)

        try await client.deleteImage(reference: ImageRef("docker.io/library/busybox:latest")!)
        #expect(await fake.calls.contains(.deleteImage("docker.io/library/busybox:latest")))
    }

    // MARK: - 错误映射（既有语义不回退）

    @Test("R14 不回退：运行时 down 时 listVolumes 报 runtimeUnavailable（probe 先行）")
    func errorMappingProbesFirst() async throws {
        let fake = FakeUpstreamClient()
        await fake.setFailListVolumes(FakeUpstreamClient.Failure(label: "boom"))
        let client = makeClient(upstream: fake, prober: .down)

        do {
            _ = try await client.listVolumes()
            Issue.record("listVolumes 应该抛错")
        } catch {
            // typed throws：这里的 error 已经是 RuntimeError（别写 `as`——编译器 bug，CLAUDE.md）
            guard case .runtimeUnavailable = error else {
                Issue.record("期望 .runtimeUnavailable，得到 \(error)")
                return
            }
        }
    }
}
