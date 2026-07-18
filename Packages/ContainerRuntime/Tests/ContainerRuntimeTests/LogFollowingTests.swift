import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// **行装配的正确性——纯逻辑，不靠真实 fd 的 OS 时序去触发（T6' DoD）。**
///
/// `readabilityHandler` 不保证按行、也不保证在 UTF-8 边界上切块（codex review P1-4）：
/// 这里钉死「按原始字节找 `\n`」这条策略在跨块、跨多字节字符时都不会拼错、不会乱码。
@Suite("LogLineAssembler：从任意 Data 块拼行")
struct LogLineAssemblerTests {

    @Test("一块里两条整行 → 两条 LogLine，顺序与内容都对")
    func assemblesTwoLinesInOneChunk() {
        var assembler = LogLineAssembler()

        let lines = assembler.consume(Data("hello\nworld\n".utf8))

        #expect(lines.map(\.text) == ["hello", "world"])
        #expect(lines.map(\.source) == [.stdout, .stdout])
        #expect(lines.map(\.sequence) == [0, 1])
    }

    @Test("一行被拆成两块（中间没有换行）→ 下一块见到 \\n 才吐出完整行")
    func assemblesLineSplitAcrossChunks() {
        var assembler = LogLineAssembler()

        let first = assembler.consume(Data("OOMOL_CONNECT_ENC".utf8))
        #expect(first.isEmpty, "半行不该提前吐出去")

        let second = assembler.consume(Data("RYPTION_KEY=abcd1234\n".utf8))
        #expect(second.map(\.text) == ["OOMOL_CONNECT_ENCRYPTION_KEY=abcd1234"])
    }

    @Test("多字节 UTF-8 字符横跨两块 → 解码正确，不乱码")
    func reassemblesMultibyteUTF8SplitAcrossChunks() {
        // 用真实的多字节汉字构造一行日志，在它的 UTF-8 字节序列中间切一刀。
        let line = "容器日志：正常启动\n"
        let bytes = Array(Data(line.utf8))
        let splitPoint = bytes.count / 2   // 大概率落在某个汉字的字节中间

        var assembler = LogLineAssembler()
        let first = assembler.consume(Data(bytes[..<splitPoint]))
        #expect(first.isEmpty)

        let second = assembler.consume(Data(bytes[splitPoint...]))
        #expect(second.map(\.text) == ["容器日志：正常启动"], "切在多字节字符中间不该产生乱码或丢字")
    }

    @Test("同一块里连续多个换行 → 产生空字符串行，不是被吞掉")
    func emptyLinesAreNotSwallowed() {
        var assembler = LogLineAssembler()

        let lines = assembler.consume(Data("a\n\nb\n".utf8))

        #expect(lines.map(\.text) == ["a", "", "b"])
    }

    @Test("consume 空 Data → 空数组，不产生任何行")
    func consumingEmptyDataProducesNoLines() {
        var assembler = LogLineAssembler()

        #expect(assembler.consume(Data()).isEmpty)
    }

    @Test("没有末尾换行的尾串 → 不在 consume 时吐出，只能靠 flush() 拿到")
    func trailingPartialLineOnlySurfacesOnFlush() {
        var assembler = LogLineAssembler()

        let consumed = assembler.consume(Data("no newline at all".utf8))
        #expect(consumed.isEmpty)

        let flushed = assembler.flush()
        #expect(flushed?.text == "no newline at all")
    }

    @Test("flush() 在没有残余字节时返回 nil，不产生空行")
    func flushWithNoPendingBytesReturnsNil() {
        var assembler = LogLineAssembler()
        _ = assembler.consume(Data("a\n".utf8))   // 已经吐完整行，没有残余

        #expect(assembler.flush() == nil)
    }

    /// codex review P1：一个**没有换行**的巨量记录若不封顶，pending 会无界增长——
    /// `LogRingBuffer` 的 byte 上限只在完整 `LogLine` 出来之后才生效，拦不住这一段。
    @Test("无换行的超长记录 → 到单行上限就强制截断吐出，pending 不无界增长")
    func unterminatedGiantRecordIsForceTruncated() {
        var assembler = LogLineAssembler(maxLineBytes: 8)

        // 一次喂 30 字节、**一个换行都没有**——不封顶的话这 30 字节会一直攒着。
        let lines = assembler.consume(Data("aaaaaaaaaabbbbbbbbbbcccccccccc".utf8))  // 30 个字节

        // 每满 8 字节就被强制吐一条（带截断标记），30 = 8+8+8 → 至少 3 条，余 6 字节还在 pending。
        #expect(lines.count >= 3, "超过上限的部分必须被截断吐出，不能全攒在 pending 里")
        #expect(lines.allSatisfy { $0.text.hasSuffix("…[truncated]") }, "强制截断吐出的行要带标记")
        // 每条截断行的原始内容恰好 8 字节（截断标记之外）。
        #expect(lines[0].text == "aaaaaaaa…[truncated]")

        // pending 里剩下的（< 上限）遇到换行才吐，且**不带**截断标记（它是完整收尾的）。
        let tail = assembler.consume(Data("\n".utf8))
        #expect(tail.count == 1)
        #expect(!tail[0].text.hasSuffix("…[truncated]"), "在上限内正常收尾的行不该被标记为截断")
    }

    @Test("截断上限只对无换行的部分生效：正常换行的短行不受影响")
    func truncationDoesNotAffectNormallyTerminatedShortLines() {
        var assembler = LogLineAssembler(maxLineBytes: 8)

        let lines = assembler.consume(Data("ok\nfine\n".utf8))

        #expect(lines.map(\.text) == ["ok", "fine"], "上限内的正常行原样吐出，不带任何标记")
    }
}

/// **策略层：一次回调该吐行还是该结束流——脱离真实 fd，用注入的 `seekToEnd` 驱动。**
@Suite("LogFollowStep：readabilityHandler 回调该做什么")
struct LogFollowStepTests {

    @Test("非空数据 → 正常吐行，不结束流")
    func nonEmptyDataYieldsLines() {
        var step = LogFollowStep()

        let outcome = step.handle(data: Data("hello\n".utf8), seekToEnd: { 0 })

        guard case .lines(let lines) = outcome else {
            Issue.record("期望 .lines，得到 \(outcome)")
            return
        }
        #expect(lines.map(\.text) == ["hello"])
    }

    @Test("空数据 + seekToEnd 成功（截断续跟）→ 不结束流，只是空转一次")
    func emptyDataWithSuccessfulSeekContinuesFollowing() {
        var step = LogFollowStep()

        let outcome = step.handle(data: Data(), seekToEnd: { 0 })

        guard case .lines(let lines) = outcome else {
            Issue.record("期望 .lines([])，得到 \(outcome)")
            return
        }
        #expect(lines.isEmpty)
    }

    @Test("空数据 + seekToEnd 失败（L1'：fd 真的死了）→ 结束流，报 RuntimeError")
    func emptyDataWithFailingSeekEndsStream() {
        var step = LogFollowStep()
        struct SeekFailure: Error {}

        let outcome = step.handle(data: Data(), seekToEnd: { throw SeekFailure() })

        guard case .finished(let trailing, let error) = outcome else {
            Issue.record("期望 .finished，得到 \(outcome)")
            return
        }
        #expect(trailing.isEmpty)
        guard case .operationFailed = error else {
            Issue.record("期望 .operationFailed，得到 \(error)")
            return
        }
    }

    @Test("结束流时若有未吐出的尾串（无末尾换行）→ 先吐尾串，不丢最后一行内容")
    func finishingFlushesTrailingPartialLine() {
        var step = LogFollowStep()
        struct SeekFailure: Error {}

        // 先喂一段没有换行的内容——它会被缓存，不会立刻吐出。
        let mid = step.handle(data: Data("last line without newline".utf8), seekToEnd: { 0 })
        guard case .lines(let midLines) = mid else {
            Issue.record("期望 .lines([])，得到 \(mid)")
            return
        }
        #expect(midLines.isEmpty)

        // 紧接着空读 + seek 失败 → 流该结束了，但那半行不该凭空消失。
        let outcome = step.handle(data: Data(), seekToEnd: { throw SeekFailure() })

        guard case .finished(let trailing, _) = outcome else {
            Issue.record("期望 .finished，得到 \(outcome)")
            return
        }
        #expect(trailing.map(\.text) == ["last line without newline"])
    }
}
