import Foundation

/// stats 窗口的 CPU%/内存占位文案 → **给人看的字符串**。跟 `SupervisorPresentation`/
/// `ContainerStatePresentation` 同一条纪律：这不是排版，是判断——散在 view 里就是零测试
/// （app target 没有测试 target）。
///
/// ## nil 与 0 的区分是判断，不是格式（P2-3）
///
/// `nil` 是「还没测出来」（首样本，或 `StatsCollector.reset()` 之后），`0` 是「量到了，
/// 真的空转」。两者混为一谈会让用户把「还没测出来」读成「容器不干活」——
/// 这条区分正是 `guard let` 挡在格式化之前的原因，不能删。
///
/// ## locale 参数（Day 14，codex 裁决 #8）
///
/// 测试必须能固定 locale，否则断言随机器区域设置漂。UI 调用方走默认 `.current`。
/// 字节格式化用 `ByteCountFormatStyle`（值类型、`Sendable`、支持 locale 注入）——
/// `ByteCountFormatter` 没有 locale 注入口。与 legacy 的输出差异已由
/// 迁移对照矩阵测试显式接受（仅 kB 档大小写，MB/GB 档一致）。
public enum StatsPresentation {

    public static func cpuPercentText(_ percent: Double?, locale: Locale = .current) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", locale: locale, percent)
    }

    public static func memoryText(
        usedBytes: UInt64?,
        limitBytes: UInt64?,
        locale: Locale = .current
    ) -> String {
        guard let usedBytes else { return "--" }
        let usedText = memoryByteText(usedBytes, locale: locale)

        guard let limitBytes else { return usedText }
        return "\(usedText) / \(memoryByteText(limitBytes, locale: locale))"
    }

    /// `.memory` 口径：与官方 CLI stats 的内存语义一致。
    private static func memoryByteText(_ bytes: UInt64, locale: Locale) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}
