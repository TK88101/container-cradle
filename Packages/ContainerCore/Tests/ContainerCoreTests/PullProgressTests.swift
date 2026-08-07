import Testing

@testable import ContainerCore

/// T2a（Day 16）：`PullProgress` 值类型 + 三档降级（§3.3）。
///
/// 字段忠于上游 `ProgressUpdateEvent`（已核 ProgressUpdate.swift:17）：items/totalItems 是 `Int`
/// 活动/项计数（**非层完成单调**，codex #11），size/totalSize 是 `Int64` 字节且**可能缺**（V3：层缓存
/// 不报字节）。UI 三档降级只由「哪个计数有值」驱动，不由 phase 驱动——故降级逻辑住 core、可测
/// （坑清单「可测性不是洁癖」），不漏进 app target。
@Suite("PullProgress 三档降级")
struct PullProgressTests {

    @Test("totalBytes 有值 → 字节分数档")
    func bytesTier() {
        let p = PullProgress(phase: "downloading", items: nil, totalItems: nil, bytes: 50, totalBytes: 100)
        #expect(p.display == .fraction(0.5))
    }

    @Test("bytes 缺、totalBytes 有值 → 已下载按 0 算")
    func bytesTierWithNilBytes() {
        let p = PullProgress(phase: "downloading", items: nil, totalItems: nil, bytes: nil, totalBytes: 100)
        #expect(p.display == .fraction(0.0))
    }

    @Test("bytes 超过 totalBytes → 分数夹到 1.0")
    func bytesTierClampsToOne() {
        let p = PullProgress(phase: "downloading", items: nil, totalItems: nil, bytes: 150, totalBytes: 100)
        #expect(p.display == .fraction(1.0))
    }

    /// totalBytes==0 无法给出有意义分数（且会除零）→ 落到下一档，不是 .fraction(NaN)。
    @Test("totalBytes==0 → 不进字节档，落到项档/不确定")
    func zeroTotalBytesFallsThrough() {
        let p = PullProgress(phase: "x", items: 3, totalItems: 7, bytes: 0, totalBytes: 0)
        #expect(p.display == .items(count: 3, total: 7))
    }

    @Test("totalBytes 缺、totalItems 有值 → 项计数档")
    func itemsTier() {
        let p = PullProgress(phase: "fetching", items: 3, totalItems: 7, bytes: nil, totalBytes: nil)
        #expect(p.display == .items(count: 3, total: 7))
    }

    @Test("items 缺、totalItems 有值 → 已完成按 0 算")
    func itemsTierWithNilItems() {
        let p = PullProgress(phase: "fetching", items: nil, totalItems: 7, bytes: nil, totalBytes: nil)
        #expect(p.display == .items(count: 0, total: 7))
    }

    @Test("字节与项都有值时，字节档优先")
    func bytesTierWinsOverItems() {
        let p = PullProgress(phase: "x", items: 3, totalItems: 7, bytes: 20, totalBytes: 40)
        #expect(p.display == .fraction(0.5))
    }

    @Test("皆无 → 不确定档")
    func indeterminateTier() {
        let p = PullProgress(phase: "preparing", items: nil, totalItems: nil, bytes: nil, totalBytes: nil)
        #expect(p.display == .indeterminate)
    }

    @Test("phase 原样保留")
    func phasePreserved() {
        let p = PullProgress(phase: "extracting", items: nil, totalItems: nil, bytes: nil, totalBytes: nil)
        #expect(p.phase == "extracting")
    }
}
