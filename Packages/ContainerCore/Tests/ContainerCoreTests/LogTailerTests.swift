import Testing

@testable import ContainerCore

/// `LogTailer`：编排「消费裸流 → 脱敏 → 写进有界 ring」的 actor。
/// 这是 D-B'（脱敏 fail-closed）与 D-C'（内存有界、暂停不停消费）两条不变式真正落地的地方。
@Suite("LogTailer：脱敏 + 有界 drain")
struct LogTailerTests {

    /// 一次性把 `lines` 灌进去然后 `finish()` 的假流——足够覆盖大多数场景。
    static func finiteStream(_ lines: [LogLine]) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    @Test("已知密钥出现在行内 → ring 里的内容已被遮蔽")
    func redactsBeforeWritingToRing() async {
        let secret = SecretString("sk-abcdef123456")
        let stream = Self.finiteStream([LogLine(text: "token=sk-abcdef123456")])

        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: [secret]))
        await tailer.awaitDrained()

        let snapshot = await tailer.snapshot()
        #expect(snapshot.count == 1)
        #expect(!snapshot[0].text.contains("sk-abcdef123456"))
    }

    /// ★ D-B'/P0-1：`.unresolved` 必须 fail closed——不建立 drain，不消费任何行。
    @Test(".unresolved → fail closed，不建立 drain，ring 保持为空")
    func unresolvedRedactionFailsClosed() async {
        let stream = Self.finiteStream([LogLine(text: "this should never be read")])

        let tailer = LogTailer(rawStream: stream, redaction: .unresolved)

        #expect(await tailer.status == .unresolved)
        #expect(await tailer.snapshot().isEmpty)
    }

    /// `.resolved(secrets: [])`（空集）是合法状态，与 `.unresolved` 必须区分对待——
    /// 空集正常 follow，不 fail closed。
    @Test(".resolved(空集) → 正常 follow，不是 fail closed")
    func resolvedWithEmptySecretsFollowsNormally() async {
        let stream = Self.finiteStream([LogLine(text: "no secrets here")])

        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))
        await tailer.awaitDrained()

        #expect(await tailer.snapshot().map(\.text) == ["no secrets here"])
    }

    @Test("clear() 之后 count 归零")
    func clearEmptiesRing() async {
        let stream = Self.finiteStream([LogLine(text: "one"), LogLine(text: "two")])
        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))
        await tailer.awaitDrained()

        await tailer.clear()

        #expect(await tailer.snapshot().isEmpty)
    }

    @Test("流正常结束 → status 变成 streamEnded(reason: nil)")
    func streamEndingNormallyMarksStatus() async {
        let stream = Self.finiteStream([LogLine(text: "bye")])
        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))

        await tailer.awaitDrained()

        #expect(await tailer.status == .streamEnded(reason: nil))
    }

    @Test("流抛错 → status 变成 streamEnded(reason: 非nil)，不崩")
    func streamThrowingMarksStatusWithReason() async {
        struct Boom: Error {}

        let stream = AsyncThrowingStream<LogLine, any Error> { continuation in
            continuation.yield(LogLine(text: "before the crash"))
            continuation.finish(throwing: Boom())
        }

        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))
        await tailer.awaitDrained()

        guard case .streamEnded(let reason) = await tailer.status else {
            Issue.record("期望 streamEnded，实际是 \(await tailer.status)")
            return
        }
        #expect(reason != nil)

        // 崩溃之前已经吐出的那一行，仍然应该被消费、写进 ring——不因为随后失败而回滚。
        #expect(await tailer.snapshot().map(\.text) == ["before the crash"])
    }

    /// ★ producer 压过 consumer：即便一次性有海量行等着被消费，ring 最终仍然有界——
    /// 这是 core 侧「不无界增长」的直接证据（M4 里程碑的另一半在桥那边，不在本次范围）。
    @Test("producer 一次性压入远超上限的行数 → ring 最终有界")
    func boundedEvenWhenProducerOutrunsConsumer() async {
        let lineCount = 20000
        let stream = AsyncThrowingStream<LogLine, any Error> { continuation in
            for index in 0..<lineCount {
                continuation.yield(LogLine(text: "flood-\(index)"))
            }
            continuation.finish()
        }

        let ring = LogRingBuffer(limits: .default)
        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []), ring: ring)
        await tailer.awaitDrained()

        let snapshot = await tailer.snapshot()
        #expect(snapshot.count == 5000)
        #expect(snapshot.last?.text == "flood-\(lineCount - 1)")
    }

    /// ★ 暂停是 view 层概念：`LogTailer` 没有暂停开关，也就没有「暂停期间不消费」这条路可测——
    /// 这里反过来证明它：即便调用方从不理会 tailer（不查询、不清屏），drain 照样把全部行
    /// 写进了有界 ring，没有卡在半路等谁来「恢复」。
    @Test("没有暂停开关：不查询 tailer 也不影响 drain 把流跑完")
    func drainCompletesWithoutAnyExternalPolling() async {
        let stream = Self.finiteStream((0..<10).map { LogLine(text: "line-\($0)") })
        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))

        await tailer.awaitDrained()

        #expect(await tailer.snapshot().count == 10)
    }

    /// ★ `cancel()` 必须能在一条永不结束的（「挂起」）流上正确收工，
    /// 且不会把「主动收工」误记成 `.streamEnded`（那会让 UI 显示一个不存在的「日志已断」提示）。
    @Test("cancel() 能让一条挂起（永不 finish）的流正确收工，不误记 streamEnded")
    func cancelStopsHangingStream() async {
        let stream = AsyncThrowingStream<LogLine, any Error> { continuation in
            continuation.yield(LogLine(text: "only line"))
            // 刻意不 finish：模拟一条仍然连着、但暂时没有新行的流。
        }

        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))

        // 先等它至少吃到那一行（用一个短暂的、确定性的方式：反复看 snapshot 直到非空，
        // 而不是 sleep 一下猜它已经消费了——CLAUDE.md「断言副作用 = 跟调度器赛跑」的教训）。
        while await tailer.snapshot().isEmpty {
            await Task.yield()
        }

        await tailer.cancel()

        // 给 cancel 的效果一点调度机会落地，再确认状态没有被错误地标成 streamEnded。
        for _ in 0..<50 {
            await Task.yield()
        }

        #expect(await tailer.status == .following, "cancel() 是主动收工，不该被误记成流结束")
        #expect(await tailer.snapshot().map(\.text) == ["only line"])
    }

    @Test("已知值出现多次 + 多行 → 全部遮蔽，写进 ring 的内容里没有任何明文子串")
    func redactsAcrossMultipleLines() async {
        let secret = SecretString("supersecretvalue")
        let stream = Self.finiteStream([
            LogLine(text: "start supersecretvalue middle"),
            LogLine(text: "supersecretvalue at the start"),
            LogLine(text: "no secret on this line"),
        ])

        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: [secret]))
        await tailer.awaitDrained()

        let snapshot = await tailer.snapshot()
        #expect(snapshot.allSatisfy { !$0.text.contains("supersecretvalue") })
        #expect(snapshot[2].text == "no secret on this line")
    }
}
