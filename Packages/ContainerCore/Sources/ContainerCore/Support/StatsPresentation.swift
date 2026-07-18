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
public enum StatsPresentation {

    public static func cpuPercentText(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }

    public static func memoryText(usedBytes: UInt64?, limitBytes: UInt64?) -> String {
        guard let usedBytes else { return "--" }
        let formatter = makeByteFormatter()
        let usedText = formatter.string(fromByteCount: Int64(clamping: usedBytes))

        guard let limitBytes else { return usedText }
        let limitText = formatter.string(fromByteCount: Int64(clamping: limitBytes))
        return "\(usedText) / \(limitText)"
    }

    /// **不缓存成 `static let`**：`ByteCountFormatter` 不是 `Sendable`（Foundation 的 `NSFormatter`
    /// 系列都不是），一个跨调用共享的静态实例在 Swift 6 严格并发检查下过不了编译
    /// （"may have shared mutable state"）。这个类型是无状态的 namespace helper，不挂在任何
    /// actor 上，调用方可能来自任意隔离域——现建一份的成本（一次格式化，不是热路径）
    /// 换来的是不必给这个 enum 强行绑一个 actor。
    private static func makeByteFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }
}
