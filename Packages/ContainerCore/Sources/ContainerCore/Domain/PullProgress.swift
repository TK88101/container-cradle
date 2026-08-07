/// 一次 image pull 的进度快照（档 A，§3.3）。domain 侧唯一表示——上游 `ProgressUpdateEvent`
/// 到 `PullMapper` 为止（D1）。
///
/// 字段忠于上游事件（已核 ProgressUpdate.swift:17）：
/// - `items`/`totalItems`：`Int` 活动/项计数。**刻意不叫「已完成层」**——上游按事件流并发更新，
///   把它当层完成的单调量会误合并并发层态（codex #11）。UI 只拿它显示 "N / M"。
/// - `bytes`/`totalBytes`：`Int64` 字节，**可能恒 nil**（V3：层缓存/此路径不报字节）。
///
/// 三档降级只由「哪个计数有值」决定（`display`），不由 `phase`——`phase` 只是给人看的活动标签，
/// 不解析成枚举（上游事件语义无稳定承诺，解析即自找漂移）。
public struct PullProgress: Sendable, Equatable {

    public let phase: String
    public let items: Int?
    public let totalItems: Int?
    public let bytes: Int64?
    public let totalBytes: Int64?

    public init(phase: String, items: Int?, totalItems: Int?, bytes: Int64?, totalBytes: Int64?) {
        self.phase = phase
        self.items = items
        self.totalItems = totalItems
        self.bytes = bytes
        self.totalBytes = totalBytes
    }

    /// UI 三档降级（§3.3）。纯逻辑住 core、可测，不漏进 app target（坑清单「可测性不是洁癖」）。
    public enum Display: Sendable, Equatable {
        /// 字节档：`totalBytes` 已知且 > 0，分数夹在 0...1。
        case fraction(Double)
        /// 项档：`totalItems` 已知（`count` 是活动/项计数，非层完成——codex #11）。
        case items(count: Int, total: Int)
        /// 不确定档：字节与项都拿不到（转圈）。
        case indeterminate
    }

    public var display: Display {
        // totalBytes==0 给不出有意义分数且会除零 → 落到下一档，不产出 NaN。
        if let totalBytes, totalBytes > 0 {
            let fraction = Double(bytes ?? 0) / Double(totalBytes)
            return .fraction(min(max(fraction, 0), 1))
        }
        if let totalItems {
            return .items(count: items ?? 0, total: totalItems)
        }
        return .indeterminate
    }
}
