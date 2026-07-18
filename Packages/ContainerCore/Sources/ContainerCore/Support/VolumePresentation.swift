import Foundation

/// Volume 窗口的显示口径 → **给人看的字符串**。跟 `StatsPresentation` 同一条纪律：
/// 这不是排版，是判断——散在 view 里就是零测试（app target 没有测试 target）。
///
/// ## 「永远双数」是 R7 的主防线之一（M5 里程碑原句）
///
/// `volume ls` 报的 512 GiB 是稀疏上限不是真实占用；单独展示它，用户会以为磁盘满了、
/// 恐慌删卷——而卷里可能是加密后不可恢复的数据。所以四个象限（有/无 used × 有/无 max）
/// **没有任何一个**允许输出孤零零的数字：拿不到就明说 unknown，不留想象空间。
///
/// ## locale 参数（Day 14，codex 裁决 #8）
///
/// 同 `StatsPresentation`：测试固定 locale，UI 走 `.current`；字节格式化迁移
/// `ByteCountFormatStyle`（`ByteCountFormatter` 无 locale 注入口），差异已由
/// 迁移对照矩阵测试显式接受（MB/GB 档一致，双数语义无损）。
public enum VolumePresentation {

    /// 列表行的容量标签：`70.1 MB used / 512 GB max`。四个象限四条目录 key，
    /// 每条都保持「双数或明示 unknown」的结构——翻译改变措辞，不许改变结构。
    public static func sizeLabel(used: UInt64?, max: UInt64?, locale: Locale = .current) -> String {
        switch (used, max) {
        case (nil, nil):
            return String(coreLocalized: "size unknown", locale: locale)
        case (let used?, nil):
            return String(
                coreLocalized: "\(fileSize(used, locale: locale)) used / max unknown",
                locale: locale
            )
        case (nil, let max?):
            return String(
                coreLocalized: "used unknown / \(fileSize(max, locale: locale)) max",
                locale: locale
            )
        case (let used?, let max?):
            return String(
                coreLocalized:
                    "\(fileSize(used, locale: locale)) used / \(fileSize(max, locale: locale)) max",
                locale: locale
            )
        }
    }

    /// 删除确认 sheet 的影响面清单（破坏性操作纪律：删除前必须列影响面）。
    ///
    /// `usedBytes == nil` 时**明示获取失败**（codex 裁决 4）——含糊的空位会让用户
    /// 在不知道卷里有多少东西的情况下删掉它。
    public static func deletionImpact(of volume: Volume, locale: Locale = .current) -> [String] {
        let usedLine =
            volume.usedBytes.map {
                String(coreLocalized: "Used: \(fileSize($0, locale: locale))", locale: locale)
            }
            ?? String(coreLocalized: "Used: unknown — size fetch failed", locale: locale)
        return [
            String(coreLocalized: "Volume: \(volume.name)", locale: locale),
            usedLine,
            String(coreLocalized: "Source: \(volume.source)", locale: locale),
            String(coreLocalized: "Created: \(iso8601(volume.creationDate))", locale: locale),
            String(
                coreLocalized: "This volume's data cannot be recovered after deletion.",
                locale: locale
            ),
        ]
    }

    /// `.file` 而非 `.memory`：磁盘容量口径，与官方 CLI `system df` 一致。
    private static func fileSize(_ bytes: UInt64, locale: Locale) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    /// ISO8601（UTC）：确定性、无本地化歧义——确认 sheet 上的时间是**核对信息**
    /// （同名重建的卷 creationDate 不同），不是装饰。刻意不随 locale 变。
    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
