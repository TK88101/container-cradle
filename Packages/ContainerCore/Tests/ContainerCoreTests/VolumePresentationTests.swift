import Foundation
import Testing
import ContainerCore

/// M5 里程碑验收的显示口径在这里被钉死：**「volume 显示真实占用而非 512 GB」= 永远双数**。
/// R7 的恐慌源正是单独一个「512 GB」——所以四个象限（有/无 used × 有/无 max）
/// 没有任何一个允许输出孤零零的数字（DAY10-DEVPLAN D-A）。
///
/// 期望值用与实现同款的 `ByteCountFormatter(.file)` 现算，不写死字符串——
/// 本地化差异（小数点、空格）不该让测试红，**结构**（双数、unknown 字样）才是断言目标。
struct VolumePresentationTests {

    private let usedBytes: UInt64 = 70_078_464          // 本机实测 open_connector_data 的真实占用
    private let maxBytes: UInt64 = 549_755_813_888      // 512 GiB 稀疏上限

    private func fileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    @Test("双数俱全：<used> used / <max> max")
    func bothKnown() {
        let label = VolumePresentation.sizeLabel(used: usedBytes, max: maxBytes)
        #expect(label == "\(fileSize(usedBytes)) used / \(fileSize(maxBytes)) max")
    }

    @Test("used 未知：明示 unknown，max 依然在场——绝不输出孤零零的 512 GB")
    func usedUnknown() {
        let label = VolumePresentation.sizeLabel(used: nil, max: maxBytes)
        #expect(label == "used unknown / \(fileSize(maxBytes)) max")
        #expect(label.contains("unknown"))
    }

    @Test("max 未知：used 在场 + max 明示 unknown")
    func maxUnknown() {
        let label = VolumePresentation.sizeLabel(used: usedBytes, max: nil)
        #expect(label == "\(fileSize(usedBytes)) used / max unknown")
    }

    @Test("双双未知：size unknown，仍不是空串")
    func bothUnknown() {
        #expect(VolumePresentation.sizeLabel(used: nil, max: nil) == "size unknown")
    }

    @Test("删除影响面：名字 / source / 用量 / 创建时间 / 不可恢复警告，一条不少")
    func deletionImpactListsEverything() {
        let volume = Volume(
            name: "data",
            creationDate: Date(timeIntervalSince1970: 1_752_000_000),
            source: "/vols/data/volume.img",
            sizeMaxBytes: maxBytes,
            usedBytes: usedBytes
        )
        let lines = VolumePresentation.deletionImpact(of: volume)
        #expect(lines.contains(where: { $0.contains("data") }))
        #expect(lines.contains(where: { $0.contains("/vols/data/volume.img") }))
        #expect(lines.contains(where: { $0.contains(fileSize(usedBytes)) }))
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
        let lines = VolumePresentation.deletionImpact(of: volume)
        #expect(lines.contains(where: { $0.contains("unknown") && $0.contains("failed") }))
    }
}
