import ContainerCore
import Foundation

/// 从任意大小的 `Data` 块里拼出完整的行。**纯逻辑，零上游类型，零 FileHandle**——
/// 这样「行装配对不对」不必靠真实 fd 的 OS 时序去触发就能被测（T6' DoD）。
///
/// ## 为什么按原始字节找 `\n`，不先解码整块再找 `\n`
///
/// `FileHandle.readabilityHandler` 不保证按行、也不保证在 UTF-8 边界上切块——
/// 一次回调可能带来半行、半个多字节字符，甚至同时带来好几行（codex review P1-4）。
///
/// UTF-8 的延续字节（`0x80`–`0xBF`）永远不等于 ASCII 换行符 `0x0A`——这是 UTF-8
/// 自同步的性质。于是「先按原始字节切出完整行，再对每一行单独解码」永远正确：
/// 被切开的多字节字符一定落在某一行的**中间**，不可能横跨 `\n`。不需要写一个
/// 真正的增量 UTF-8 状态机，也不会因为在半个字符处切块而把它解码成乱码。
struct LogLineAssembler {

    /// 单行硬上限（字节）。一个**没有换行**的巨量记录若不封顶，`pending` 会一直涨到
    /// 换行/流结束才释放——`LogRingBuffer` 的 byte 上限只在**完整的 `LogLine` 出来之后**
    /// 才生效，拦不住这一段（codex review P1）。超过上限就**强制截断吐出**，于是
    /// `pending` 永远 ≤ 上限 + 一次回调的块大小，「follow chatty 容器内存不涨」在
    /// 无换行的病态输入下也成立。
    static let defaultMaxLineBytes = 64 * 1024

    private let maxLineBytes: Int
    private var pending = Data()
    private var nextSequence = 0

    init(maxLineBytes: Int = LogLineAssembler.defaultMaxLineBytes) {
        precondition(maxLineBytes > 0, "maxLineBytes 必须为正——非法配置在这里夹掉")
        self.maxLineBytes = maxLineBytes
    }

    /// 喂一块原始字节，吐出这一块里已经凑齐的整行（可能 0 条、可能多条）。
    /// 半行（还没见到 `\n`）留在内部状态里，等下一块或 `flush()`——**除非它超过
    /// `maxLineBytes`**，那时强制截断吐出，不许无界攒着（codex review P1）。
    ///
    /// ## C5：一次回调吐出多条行时，只压缩一次
    ///
    /// 原先每吐一行就 `removeSubrange` 一次——一个回调若凑出 k 条整行，就是 k 次 O(n)
    /// 搬移，O(k·n)。这里改成用游标向前扫（`pending` 本身不动），扫完这一块所有能吐的行
    /// 之后再一次性 `removeSubrange` 到游标位置，把 O(k·n) 压回 O(n)。
    mutating func consume(_ data: Data) -> [LogLine] {
        guard !data.isEmpty else { return [] }
        pending.append(data)

        var lines: [LogLine] = []
        var cursor = pending.startIndex

        while true {
            if let newline = pending[cursor...].firstIndex(of: 0x0A) {
                lines.append(makeLine(from: pending[cursor..<newline], truncated: false))
                cursor = pending.index(after: newline)
                continue
            }
            // 没换行但已超单行上限 → 截断吐出前 maxLineBytes 字节，别让 pending 无界涨。
            if pending.distance(from: cursor, to: pending.endIndex) > maxLineBytes {
                let cut = pending.index(cursor, offsetBy: maxLineBytes)
                lines.append(makeLine(from: pending[cursor..<cut], truncated: true))
                cursor = cut
                continue
            }
            break
        }

        if cursor > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<cursor)
        }

        return lines
    }

    /// 把没有末尾换行的残余字节吐成一行（若有）。**只在流真的要结束时调用**——
    /// 正常 follow 过程中半行永远留着等下一块，不许提前吐出去（那会把一行拆成两条）。
    mutating func flush() -> LogLine? {
        guard !pending.isEmpty else { return nil }
        let line = makeLine(from: pending[pending.startIndex...], truncated: false)
        pending.removeAll()
        return line
    }

    private mutating func makeLine(from bytes: Data.SubSequence, truncated: Bool) -> LogLine {
        defer { nextSequence += 1 }
        // `String(decoding:as:)` 对非法字节序列产出替换字符，不抛错——
        // 日志是容器写的自由文本，没有 schema 承诺，桥层不能因为一段脏字节就判整条流失败。
        // 截断处按字节切，可能切在多字节字符中间 → 那半个字符解成替换字符，不影响后续行。
        var text = String(decoding: bytes, as: UTF8.self)
        if truncated {
            text += "…[truncated]"
        }
        return LogLine(text: text, source: .stdout, sequence: nextSequence)
    }
}

/// 把「一次 `readabilityHandler` 回调该做什么」跟「怎么注册这个回调」分开。
///
/// mechanism（`LiveContainerRuntimeClient.followLogs` 里对 `FileHandle.readabilityHandler`
/// 的接线）只做一件事：把每次回调的数据、和一个「怎么 seekToEnd」的能力交给这里；
/// 这里决定吐哪些行、要不要结束流——**这部分分支不需要真实 fd 的 OS 事件时序就能被单测**。
struct LogFollowStep {

    enum Outcome {
        /// 这次回调吐出的整行（可能是空数组——纯粹的半行缓存，或者是一次无意义的空 seek 重试）。
        case lines([LogLine])

        /// 流该结束了（`seekToEnd` 失败——上游套路里这代表 fd 真的死了，不是可恢复的截断）。
        /// `trailing`：结束前把还没吐出去的半行（没有末尾换行）先吐掉，不丢最后一行内容。
        case finished(trailing: [LogLine], error: RuntimeError)
    }

    private var assembler = LogLineAssembler()

    /// - Parameters:
    ///   - data: 这次回调读到的原始字节。空 = 触发空读处理（见下）。
    ///   - seekToEnd: 空读时尝试跳到文件尾继续跟随（上游套路：容器重启会截断日志文件，
    ///     `seekToEnd()` 成功就说明还能继续跟着新内容走）。**抛错 = 这个 fd 真的死了**——
    ///     不静默假装还在跟随（L1'）。
    mutating func handle(data: Data, seekToEnd: () throws -> UInt64) -> Outcome {
        guard !data.isEmpty else {
            do {
                _ = try seekToEnd()
                return .lines([])
            } catch {
                let trailing = assembler.flush().map { [$0] } ?? []
                return .finished(
                    trailing: trailing,
                    error: .operationFailed(reason: "日志流已结束（seek 失败：\(error)）")
                )
            }
        }

        return .lines(assembler.consume(data))
    }
}
