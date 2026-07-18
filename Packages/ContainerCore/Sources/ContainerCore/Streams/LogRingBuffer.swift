import Foundation

/// 有界的日志缓冲——**M4 里程碑「follow chatty 容器 10 分钟，内存不涨」的全部依据**。
///
/// ## 三重界，不是一重（P1-1/P1-2，codex review 定案）
///
/// 「5000 行」单独不是内存界：一行可以任意大（容器把一个几十 MB 的 base64 blob 打成一行），
/// 5000 个巨串照样能把内存撑爆。所以：
///
/// - **单行字节上限**（`Limits.maxLineBytes`）：超限截断 + `…[truncated]` 标记。
/// - **总保留字节上限**（`Limits.maxTotalBytes`）：即便每行都不超限，行数够多照样能超总量，
///   到顶也丢最旧——和行数上限是**两个独立的淘汰触发条件**，任一个超了就淘汰到两个都不超。
/// - **行数上限**（`Limits.maxLineCount`，默认 5000）：即便每行都很短，行数本身也要封顶。
///
/// ## 为什么是 actor
///
/// `LogTailer` 的 drain 循环（写者）和 UI 的定期快照（读者）并发访问同一份缓冲。
/// actor 把这层同步交给编译器强制，不必自己管锁。
///
/// ## `snapshot()` 是只读复制，不是引用
///
/// Swift `Array` 是值类型：`snapshot()` 返回的那份数组，后续的 `append`/`clear` 不会
/// 反过来改动它。UI 层可以放心地把它塞进 `@Observable` 状态，不用担心「别处偷偷改了我手上这份」。
public actor LogRingBuffer {

    public struct Limits: Sendable, Equatable {
        public let maxLineCount: Int
        public let maxLineBytes: Int
        public let maxTotalBytes: Int

        /// 三个上限都被夹到至少 1——非法值（0 或负数）在这里夹掉，不靠「调用方不会那么填」
        /// （`SupervisorConfig` 的同一条纪律：CLAUDE.md「边界值会绕过硬约束」）。
        /// 夹成 0 尤其危险：`evictIfNeeded` 的判据是 `count > limit`，`limit == 0` 会让
        /// 每次 `append` 之后立刻把刚写进去的那一行自己淘汰掉——「有界」退化成「什么都存不住」。
        public init(maxLineCount: Int = 5000, maxLineBytes: Int = 8192, maxTotalBytes: Int = 2_000_000) {
            self.maxLineCount = max(maxLineCount, 1)
            self.maxLineBytes = max(maxLineBytes, 1)
            self.maxTotalBytes = max(maxTotalBytes, 1)
        }

        public static let `default` = Limits()
    }

    private let limits: Limits
    private var lines: [RedactedLogLine] = []

    /// C3：逻辑起点。`removeFirst()` 每次都是 O(n) 搬移——chatty 容器每秒几十行、
    /// 稳态下几乎每次 `append` 都触发一次淘汰，O(n) each 就是 O(n²) 累计。
    /// 这里改成**摊还 O(1)**：淘汰只推进 `head`（逻辑删除，不搬数组），死前缀积到
    /// `limits.maxLineCount` 才一次性 `removeSubrange` 压缩——见 `compactIfNeeded()`。
    private var head = 0

    private var totalBytes = 0

    /// 单调递增，**清屏不重置**——`RedactedLogLine.id` 的文档：UI 靠它区分清屏前后的内容。
    private var nextID = 0

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// 追加一行。超长的 `text` 在这里截断；追加之后若任一上限被突破，从头淘汰到两个都不再突破。
    public func append(text: String, source: LogStreamKind) {
        let bounded = Self.truncated(text, limit: limits.maxLineBytes)
        let line = RedactedLogLine(id: nextID, text: bounded, source: source)
        nextID += 1

        lines.append(line)
        totalBytes += bounded.utf8.count

        evictIfNeeded()
    }

    /// 清屏：清空内容，**不重置 `nextID`**、不影响是否仍在 follow（那是 `LogTailer` 的状态）。
    public func clear() {
        lines.removeAll()
        head = 0
        totalBytes = 0
    }

    public func snapshot() -> [RedactedLogLine] {
        Array(lines[head...])
    }

    public var count: Int { lines.count - head }

    // MARK: -

    private func evictIfNeeded() {
        while (count > limits.maxLineCount || totalBytes > limits.maxTotalBytes), count > 0 {
            totalBytes -= lines[head].text.utf8.count
            head += 1
        }

        compactIfNeeded()
    }

    /// 摊还 O(1) 的另一半：死前缀（`head` 之前、已经逻辑淘汰的元素）积到跟
    /// `limits.maxLineCount` 一样大才压缩一次——单次压缩是 O(n)，但摊到「攒够
    /// `maxLineCount` 次淘汰才压一次」上，均摊回 O(1)。阈值选得比这更小
    /// （比如每次淘汰都压）就退化回原来的「每次 O(n)」；选得更大只是让底层数组
    /// 多背一截用不上的死前缀，上限仍然是 `maxLineCount`，不会无界增长。
    private func compactIfNeeded() {
        guard head >= limits.maxLineCount else { return }
        lines.removeSubrange(0..<head)
        head = 0
    }

    /// 按 UTF-8 字节裁到 `limit` 以内，且不切断多字节字符（沿 `Character` 边界裁，
    /// 而不是裸字节切片——裸切片可能把一个 emoji 切成半个，产出非法 UTF-8）。
    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }

        var kept = ""
        var bytes = 0
        for character in text {
            let characterBytes = String(character).utf8.count
            guard bytes + characterBytes <= limit else { break }
            kept.append(character)
            bytes += characterBytes
        }
        return kept + "…[truncated]"
    }
}
