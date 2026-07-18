import Foundation
import Testing
import ContainerCore

/// M5 里程碑验收的显示口径在这里被钉死：**「volume 显示真实占用而非 512 GB」= 永远双数**。
/// R7 的恐慌源正是单独一个「512 GB」——所以四个象限（有/无 used × 有/无 max）
/// 没有任何一个允许输出孤零零的数字（DAY10-DEVPLAN D-A）。
///
/// Day 14 起：期望值不再「与实现同款现算」——那种写法守不住 formatter 迁移的行为漂
/// （codex #4）。改为显式传 `en_US_POSIX` + 写死具体串；本地化差异由 locale 参数隔离，
/// 结构（双数、unknown 字样）与措辞一起钉死。
struct VolumePresentationTests {

    private let posix = Locale(identifier: "en_US_POSIX")
    private let usedBytes: UInt64 = 70_078_464          // 本机实测 open_connector_data 的真实占用
    private let maxBytes: UInt64 = 549_755_813_888      // 512 GiB 稀疏上限

    @Test("双数俱全：<used> used / <max> max")
    func bothKnown() {
        let label = VolumePresentation.sizeLabel(used: usedBytes, max: maxBytes, locale: posix)
        #expect(label == "70.1 MB used / 549.76 GB max")
    }

    @Test("used 未知：明示 unknown，max 依然在场——绝不输出孤零零的 512 GB")
    func usedUnknown() {
        let label = VolumePresentation.sizeLabel(used: nil, max: maxBytes, locale: posix)
        #expect(label == "used unknown / 549.76 GB max")
    }

    @Test("max 未知：used 在场 + max 明示 unknown")
    func maxUnknown() {
        let label = VolumePresentation.sizeLabel(used: usedBytes, max: nil, locale: posix)
        #expect(label == "70.1 MB used / max unknown")
    }

    @Test("双双未知：size unknown，仍不是空串")
    func bothUnknown() {
        #expect(VolumePresentation.sizeLabel(used: nil, max: nil, locale: posix) == "size unknown")
    }

    // MARK: - ByteCountFormatStyle 迁移对照矩阵（codex #4）

    /// 2026-07-18 实测：`.file` 口径在 MB/GB 档与 `ByteCountFormatter` 完全一致
    /// （70.1 MB / 549.76 GB——**双数显示语义 R7 无损**），差异仅 kB 档大小写
    /// （legacy `KB` → new `kB`、`Zero KB` → `Zero kB`）。真实 volume 均在 MB/GB 档，
    /// **显式接受**该差异并由本矩阵钉死。`.memory` 口径对照见 StatsPresentationTests。
    @Test(
        "迁移矩阵（.file, en_US_POSIX）：0/1KiB/1MiB/70MB/512GiB 输出钉死",
        arguments: [
            (UInt64(0), "Zero kB"),
            (UInt64(1_024), "1 kB"),
            (UInt64(1_048_576), "1 MB"),
            (UInt64(70_078_464), "70.1 MB"),
            (UInt64(549_755_813_888), "549.76 GB"),
        ] as [(UInt64, String)]
    )
    func fileMigrationMatrix(bytes: UInt64, expected: String) {
        let label = VolumePresentation.sizeLabel(used: bytes, max: nil, locale: posix)
        #expect(label == "\(expected) used / max unknown")
    }

    /// zh-Hans 目录命中（codex #5 高价值面）：容量标签双数象限整句 exact。
    @Test("zh-Hans：双数标签命中目录，非 key 回显")
    func sizeLabelZhHans() {
        let label = VolumePresentation.sizeLabel(
            used: usedBytes,
            max: maxBytes,
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(label == "已用 70.1 MB / 上限 549.76 GB")
    }

    // MARK: - 删除影响面

    @Test("删除影响面：名字 / source / 用量 / 创建时间 / 不可恢复警告，一条不少")
    func deletionImpactListsEverything() {
        let volume = Volume(
            name: "data",
            creationDate: Date(timeIntervalSince1970: 1_752_000_000),
            source: "/vols/data/volume.img",
            sizeMaxBytes: maxBytes,
            usedBytes: usedBytes
        )
        let lines = VolumePresentation.deletionImpact(of: volume, locale: posix)
        #expect(lines.contains(where: { $0.contains("data") }))
        #expect(lines.contains(where: { $0.contains("/vols/data/volume.img") }))
        #expect(lines.contains(where: { $0.contains("70.1 MB") }))
        // 创建时间用 ISO8601（UTC，确定性）：1_752_000_000 = 2025-07-08T18:40:00Z
        #expect(lines.contains(where: { $0.contains("2025-07-08T18:40:00Z") }))
        #expect(lines.contains(where: { $0.localizedCaseInsensitiveContains("cannot be recovered") }))
    }

    @Test("删除影响面：used 拿不到时必须明示获取失败，不许留含糊空位（★R1 裁决 4）")
    func deletionImpactFlagsUnknownUsage() {
        let volume = Volume(
            name: "data",
            creationDate: Date(timeIntervalSince1970: 1_752_000_000),
            source: "/vols/data/volume.img",
            sizeMaxBytes: maxBytes,
            usedBytes: nil
        )
        let lines = VolumePresentation.deletionImpact(of: volume, locale: posix)
        #expect(lines.contains(where: { $0.contains("unknown") && $0.contains("failed") }))
    }
}
