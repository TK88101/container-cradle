import ContainerAPIClient
import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// **真机 M5：volume 生命周期 + image infra 过滤。**
///
/// 单测喂的全是 Fake——`ClientVolume` / `ClientImage` / config 加载这三条真 XPC 路径
/// 一次都没跑过（「被豁免的那一层最容易藏 P1」）。这里跑真的。
///
/// ## 删除演练的靶子纪律（★R1 裁决 6 + ★R2 裁决 R2-2）
///
/// - 靶子**自建**：`cof-m5-itest-<UUID>`，创建时打 owner label。
/// - 清理只删「前缀 ∧ owner label」双匹配；同前缀无 label 的卷**跳过并报告，绝不删**
///   ——前缀匹配 ≠ 本测试自建，用户可能恰好建了同前缀卷（误删 = R7 事故）。
/// - `defer` 兜不住进程被 kill——所以开头先扫上一次的残留（带 label 的才扫）。
/// - `open_connector_data` 从头到尾**不出现在任何断言里**（去本机化，裁决 7）。
///
/// `INTEGRATION=1 swift test` 才跑。
@Suite(
    "真机 M5：volume 生命周期 + image infra 过滤",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1")
)
struct VolumeImageIntegrationTests {

    private static let namePrefix = "cof-m5-itest-"
    private static let ownerLabelKey = "com.cradleoffilth.test.owner"
    private static let ownerLabelValue = "m5-integration"

    /// ★R2-2：清理上次运行的残留。只删双匹配（前缀 ∧ label）；其余同前缀卷报告不删。
    private func sweepLeftovers() async throws {
        for config in try await ClientVolume.list() where config.name.hasPrefix(Self.namePrefix) {
            if config.labels[Self.ownerLabelKey] == Self.ownerLabelValue {
                try? await ClientVolume.delete(name: config.name)
            } else {
                Issue.record(
                    "发现同前缀但无 owner label 的卷 '\(config.name)'——不是本测试建的，跳过不删，请人工确认"
                )
            }
        }
    }

    @Test("真 XPC：自建卷 create → list（usage 路由真的通）→ inspect → deleteVolume → 消失")
    func volumeLifecycleRoundtrip() async throws {
        try await sweepLeftovers()

        let name = Self.namePrefix + UUID().uuidString.lowercased()
        _ = try await ClientVolume.create(
            name: name,
            labels: [Self.ownerLabelKey: Self.ownerLabelValue]
        )

        let client = LiveContainerRuntimeClient()

        // list：能看见 + usage 路由真的走通（fail-soft 会把路由坏死掩盖成全 nil，
        // 单测照不出来——所以真机必须断言 non-nil；空卷的 0 也是 non-nil）。
        let volumes = try await client.listVolumes()
        let created = try #require(volumes.first(where: { $0.name == name }))
        #expect(created.usedBytes != nil, "usage 路由没走通（.volumeDiskUsage）")
        #expect(created.sizeMaxBytes != nil, "稀疏上限没映射出来")
        #expect(!created.source.isEmpty)

        // inspect：identity-only 快路径。
        let inspected = try #require(try await client.inspectVolume(named: name))
        #expect(inspected.matchesIdentity(of: created))
        #expect(inspected.usedBytes == nil)

        // 删除演练的自动化形态：identity 复核 + 真删 + 列表复核。
        try await client.deleteVolume(created)
        let after = try await client.listVolumes()
        #expect(!after.contains(where: { $0.name == name }))

        // 兜底：正常路径上面已删，这句只在断言之前就炸了的场景有用。
        try? await ClientVolume.delete(name: name)
    }

    @Test("真 XPC：listImages 旗标权威（stock 环境）且 infra 引用不可见")
    func imagesFilterIsAuthoritativeAndHidesInfra() async throws {
        let client = LiveContainerRuntimeClient()

        let snapshot = try await client.listImages()
        #expect(snapshot.isInfraFilterAuthoritative, "stock 环境下 config 加载失败了？")

        // 「infra 不可见」用**真实加载**的 refs 断言（与过滤同源），
        // 不断言 open-connector 等本机私有镜像（裁决 7：去本机化）。
        let infraRefs = try await LiveUpstreamClient().loadedInfraImageReferences()
        #expect(!infraRefs.isEmpty, "config 里连 builder/vminit 都没有？")
        for image in snapshot.images {
            #expect(
                !infraRefs.contains(image.reference.rawValue),
                "infra 镜像 \(image.reference.rawValue) 泄进了 domain 列表"
            )
        }
    }
}
