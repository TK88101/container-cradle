import Foundation
import Testing
import ContainerCore

/// M5：Fake 的 volume/image 语义。**Fake 的语义必须对齐真运行时**（既定纪律）——
/// 尤其 ★R3 的 identity 语义：`deleteVolume` 对「同名但 fingerprint 不同」的 target
/// 必须拒绝，store 的测试因此顺带在真语义上跑。
struct FakeVolumeAndImageClientTests {

    private func makeVolume(
        name: String = "data",
        created: Date = Date(timeIntervalSince1970: 1_752_000_000),
        source: String = "/vols/data/volume.img",
        used: UInt64? = 70_078_464
    ) -> Volume {
        Volume(name: name, creationDate: created, source: source, sizeMaxBytes: 549_755_813_888, usedBytes: used)
    }

    private func makeImage(_ reference: String = "docker.io/library/busybox:latest") -> ImageSummary {
        ImageSummary(reference: ImageRef(reference)!, digest: "sha256:0123456789abcdef")
    }

    // MARK: - Volume

    @Test("listVolumes 返回配置的卷 + 记录流水")
    func listVolumesReturnsConfigured() async throws {
        let volume = makeVolume()
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [volume])
        let listed = try await fake.listVolumes()
        #expect(listed == [volume])
        #expect(await fake.calls.contains(.listVolumes))
    }

    @Test("listVolumes 可注入失败")
    func listVolumesInjection() async throws {
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [makeVolume()])
        await fake.inject(.runtimeUnavailable, for: .listVolumes)
        await #expect(throws: RuntimeError.self) { try await fake.listVolumes() }
        // 试过但失败了 ≠ 压根没试：流水必须有记录
        #expect(await fake.calls.contains(.listVolumes))
    }

    @Test("inspectVolume 是 identity-only：同 identity 但 usedBytes 恒 nil（★R2）")
    func inspectVolumeIsIdentityOnly() async throws {
        let volume = makeVolume(used: 70_078_464)
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [volume])
        let inspected = try await fake.inspectVolume(named: "data")
        let unwrapped = try #require(inspected)
        #expect(unwrapped.matchesIdentity(of: volume))
        #expect(unwrapped.usedBytes == nil)
        #expect(await fake.calls.contains(.inspectVolume("data")))
    }

    @Test("inspectVolume 未知名字 → nil（不是抛错——not-found 用缺席表达，不嗅错误文本）")
    func inspectVolumeUnknownIsNil() async throws {
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [makeVolume()])
        #expect(try await fake.inspectVolume(named: "ghost") == nil)
    }

    @Test("deleteVolume：identity 匹配 → 删除成功，列表里消失")
    func deleteVolumeRemovesMatchingTarget() async throws {
        let volume = makeVolume()
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [volume])
        try await fake.deleteVolume(volume)
        #expect(try await fake.listVolumes().isEmpty)
        #expect(await fake.calls.contains(.deleteVolume("data")))
    }

    @Test("★R3 deleteVolume：同名但 fingerprint 不同（同名重建）→ 拒绝且卷原地不动")
    func deleteVolumeRejectsStaleTarget() async throws {
        let current = makeVolume(created: Date(timeIntervalSince1970: 1_752_000_999))
        let stale = makeVolume(created: Date(timeIntervalSince1970: 1_752_000_000))
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [current])
        await #expect(throws: RuntimeError.self) { try await fake.deleteVolume(stale) }
        #expect(try await fake.listVolumes() == [current])
    }

    @Test("deleteVolume：卷不存在 → 抛错（上游如此，不静默成功）")
    func deleteVolumeMissingThrows() async throws {
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [])
        await #expect(throws: RuntimeError.self) { try await fake.deleteVolume(makeVolume()) }
    }

    @Test("deleteVolume 可注入失败，且失败时卷原地不动")
    func deleteVolumeInjection() async throws {
        let volume = makeVolume()
        let fake = FakeContainerRuntimeClient(containers: [], volumes: [volume])
        await fake.inject(.operationFailed(reason: "volume is in use"), for: .deleteVolume)
        await #expect(throws: RuntimeError.self) { try await fake.deleteVolume(volume) }
        #expect(try await fake.listVolumes() == [volume])
    }

    // MARK: - Image

    @Test("listImages 返回快照，权威旗标可配置（D-C 的数据源）")
    func listImagesCarriesFlag() async throws {
        let image = makeImage()
        let fake = FakeContainerRuntimeClient(containers: [], images: [image])
        let snapshot = try await fake.listImages()
        #expect(snapshot.images == [image])
        #expect(snapshot.isInfraFilterAuthoritative)

        await fake.setInfraFilterAuthoritative(false)
        let degraded = try await fake.listImages()
        #expect(!degraded.isInfraFilterAuthoritative)
        #expect(await fake.calls.contains(.listImages))
    }

    @Test("deleteImage：存在 → 删除；不存在 → 抛错")
    func deleteImageSemantics() async throws {
        let image = makeImage()
        let fake = FakeContainerRuntimeClient(containers: [], images: [image])
        try await fake.deleteImage(reference: image.reference)
        #expect(try await fake.listImages().images.isEmpty)
        #expect(await fake.calls.contains(.deleteImage(image.reference)))

        await #expect(throws: RuntimeError.self) {
            try await fake.deleteImage(reference: ImageRef("ghost:latest")!)
        }
    }

    @Test("deleteImage 语义对齐 live：非权威 → 拒绝且镜像原地不动（codex P2）")
    func deleteImageRefusesWhenNotAuthoritative() async throws {
        let image = makeImage()
        let fake = FakeContainerRuntimeClient(
            containers: [], images: [image], isInfraFilterAuthoritative: false
        )
        await #expect(throws: RuntimeError.self) {
            try await fake.deleteImage(reference: image.reference)
        }
        await fake.setInfraFilterAuthoritative(true)
        #expect(try await fake.listImages().images == [image])
    }

    @Test("listImages / deleteImage 可注入失败")
    func imageInjection() async throws {
        let image = makeImage()
        let fake = FakeContainerRuntimeClient(containers: [], images: [image])
        await fake.inject(.runtimeUnavailable, for: .listImages)
        await #expect(throws: RuntimeError.self) { _ = try await fake.listImages() }

        await fake.inject(.operationFailed(reason: "cannot confirm infra filter"), for: .deleteImage)
        await #expect(throws: RuntimeError.self) { try await fake.deleteImage(reference: image.reference) }
        // 注入失败不许动数据
        await fake.inject(nil, for: .listImages)
        #expect(try await fake.listImages().images == [image])
    }
}
