import Foundation
import Testing
import ContainerCore

/// M5 域类型：`Volume` / `ImageSummary` / `ImageListSnapshot`。
///
/// `matchesIdentity` 是 R7 防线的判据（DAY10-DEVPLAN ★R1/★R3）：删除前复核
/// 「同名卷还是不是确认时那个卷」。**用量不参与 identity**——它每秒都在漂。
struct VolumeDomainTests {

    private func makeVolume(
        name: String = "data",
        created: Date = Date(timeIntervalSince1970: 1_752_000_000),
        source: String = "/vols/data/volume.img",
        max: UInt64? = 549_755_813_888,
        used: UInt64? = 70_078_464
    ) -> Volume {
        Volume(name: name, creationDate: created, source: source, sizeMaxBytes: max, usedBytes: used)
    }

    @Test("同 identity、不同用量 → matchesIdentity 为真（usedBytes/sizeMaxBytes 不参与）")
    func identityIgnoresUsage() {
        let shown = makeVolume(max: 549_755_813_888, used: 70_078_464)
        let refetched = makeVolume(max: nil, used: nil)
        #expect(shown.matchesIdentity(of: refetched))
        #expect(refetched.matchesIdentity(of: shown))
    }

    @Test("name 变了 → 不是同一个卷")
    func identityBreaksOnName() {
        #expect(!makeVolume().matchesIdentity(of: makeVolume(name: "data2")))
    }

    @Test("creationDate 变了 → 同名重建，不是同一个卷")
    func identityBreaksOnCreationDate() {
        let rebuilt = makeVolume(created: Date(timeIntervalSince1970: 1_752_000_001))
        #expect(!makeVolume().matchesIdentity(of: rebuilt))
    }

    @Test("source 变了 → 不是同一个卷")
    func identityBreaksOnSource() {
        #expect(!makeVolume().matchesIdentity(of: makeVolume(source: "/vols/other/volume.img")))
    }

    @Test("Identifiable：id 就是 name（列表渲染用）")
    func idIsName() {
        #expect(makeVolume(name: "data").id == "data")
    }
}

struct ImageSummaryDomainTests {

    @Test("shortDigest 剥掉 sha256: 前缀并截到 12 位")
    func shortDigestStripsPrefixAndTruncates() {
        let summary = ImageSummary(
            reference: ImageRef("ghcr.io/oomol-lab/open-connector:latest")!,
            digest: "sha256:ccff714537b5deadbeefcafe0123456789abcdef0123456789abcdef012345"
        )
        #expect(summary.shortDigest == "ccff714537b5")
    }

    @Test("无前缀的 digest 直接截 12 位")
    func shortDigestWithoutPrefix() {
        let summary = ImageSummary(
            reference: ImageRef("docker.io/library/busybox:latest")!,
            digest: "0123456789abcdef"
        )
        #expect(summary.shortDigest == "0123456789ab")
    }

    @Test("digest 不足 12 位 → 原样返回，不崩")
    func shortDigestShorterThanTwelve() {
        let summary = ImageSummary(
            reference: ImageRef("docker.io/library/busybox:latest")!,
            digest: "sha256:abc"
        )
        #expect(summary.shortDigest == "abc")
    }

    @Test("ImageListSnapshot 携带权威旗标（D-C fail-closed 的数据源）")
    func snapshotCarriesAuthoritativeFlag() {
        let summary = ImageSummary(
            reference: ImageRef("docker.io/library/busybox:latest")!,
            digest: "sha256:abc"
        )
        let authoritative = ImageListSnapshot(images: [summary], isInfraFilterAuthoritative: true)
        let degraded = ImageListSnapshot(images: [summary], isInfraFilterAuthoritative: false)
        #expect(authoritative.isInfraFilterAuthoritative)
        #expect(!degraded.isInfraFilterAuthoritative)
        #expect(authoritative.images == degraded.images)
    }
}
