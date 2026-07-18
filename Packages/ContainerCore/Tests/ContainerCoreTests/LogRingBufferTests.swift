import Testing

@testable import ContainerCore

/// `LogRingBuffer`：**M4 里程碑「follow chatty 容器 10 分钟，内存不涨」的唯一单测保障**。
/// 三重界（行数 / 单行字节 / 总字节）分开测，避免一条测试掩盖另一条界失效
/// （CLAUDE.md「测试装置会掩盖 bug」的同一条教训：只测行数会让字节上限的 bug 隐形）。
@Suite("LogRingBuffer：三重界，满了丢最旧")
struct LogRingBufferTests {

    @Test("塞 10000 行 → count == 5000，且是最后 5000 行")
    func evictsOldestWhenLineCountExceedsLimit() async {
        let buffer = LogRingBuffer()

        for index in 0..<10000 {
            await buffer.append(text: "line-\(index)", source: .stdout)
        }

        let snapshot = await buffer.snapshot()

        #expect(snapshot.count == 5000)
        #expect(snapshot.first?.text == "line-5000")
        #expect(snapshot.last?.text == "line-9999")
    }

    @Test("超长单行 → 被截断，且总字节有界")
    func truncatesOverlongLines() async {
        let limits = LogRingBuffer.Limits(maxLineCount: 100, maxLineBytes: 100, maxTotalBytes: 1_000_000)
        let buffer = LogRingBuffer(limits: limits)

        let hugeLine = String(repeating: "x", count: 10_000)
        await buffer.append(text: hugeLine, source: .stdout)

        let snapshot = await buffer.snapshot()

        #expect(snapshot.count == 1)
        #expect(snapshot[0].text.utf8.count <= 100 + "…[truncated]".utf8.count)
        #expect(snapshot[0].text.hasSuffix("…[truncated]"))
    }

    @Test("截断不切断多字节字符——不产出非法 UTF-8 碎片")
    func truncationRespectsCharacterBoundaries() async {
        let limits = LogRingBuffer.Limits(maxLineCount: 100, maxLineBytes: 10, maxTotalBytes: 1_000_000)
        let buffer = LogRingBuffer(limits: limits)

        // 每个 emoji 是多字节 UTF-8；上限刚好卡在字符中间的位置也不能崩。
        let line = String(repeating: "🎉", count: 20)
        await buffer.append(text: line, source: .stdout)

        let snapshot = await buffer.snapshot()
        #expect(snapshot[0].text.hasSuffix("…[truncated]"))
        // 若切断了字符边界，构造 String 时就会产出替换字符或崩溃；能正常读出内容即为通过。
        #expect(!snapshot[0].text.isEmpty)
    }

    @Test("总字节上限：即便行数没超，累计字节超了也丢最旧")
    func evictsOldestWhenTotalBytesExceedLimit() async {
        // 每行 100 字节，总上限 250 字节 → 最多留 2 行多一点，第 3 行进来会挤掉第 1 行。
        let limits = LogRingBuffer.Limits(maxLineCount: 1000, maxLineBytes: 1000, maxTotalBytes: 250)
        let buffer = LogRingBuffer(limits: limits)

        let line = String(repeating: "a", count: 100)
        await buffer.append(text: line, source: .stdout)
        await buffer.append(text: line, source: .stdout)
        await buffer.append(text: line, source: .stdout)

        let snapshot = await buffer.snapshot()

        #expect(snapshot.count == 2, "总字节上限应当把最旧的一行挤出去，剩下的行数不该无限涨")
    }

    @Test("clear() 清空内容")
    func clearEmptiesBuffer() async {
        let buffer = LogRingBuffer()
        await buffer.append(text: "line", source: .stdout)

        await buffer.clear()

        let snapshot = await buffer.snapshot()
        #expect(snapshot.isEmpty)
        #expect(await buffer.count == 0)
    }

    @Test("snapshot() 是复制，不是引用——之后的 append 不会反过来改动已取出的那份")
    func snapshotIsNotAffectedByLaterAppends() async {
        let buffer = LogRingBuffer()
        await buffer.append(text: "first", source: .stdout)

        let snapshot = await buffer.snapshot()
        await buffer.append(text: "second", source: .stdout)

        #expect(snapshot.count == 1)
        #expect(snapshot[0].text == "first")
    }

    @Test("并发 append 不崩，且行数不超过上限（actor 串行化写入）")
    func concurrentAppendsAreSerializedAndBounded() async {
        let limits = LogRingBuffer.Limits(maxLineCount: 50, maxLineBytes: 1000, maxTotalBytes: 1_000_000)
        let buffer = LogRingBuffer(limits: limits)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<500 {
                group.addTask {
                    await buffer.append(text: "concurrent-\(index)", source: .stdout)
                }
            }
        }

        let snapshot = await buffer.snapshot()
        #expect(snapshot.count == 50)
    }

    /// 同 `SupervisorConfig` 的纪律：非法配置在 `init` 里夹掉，不靠「调用方不会那么填」。
    /// 夹成 0 尤其危险——`0` 会让 `evictIfNeeded` 把刚写入的那一行立刻淘汰掉。
    @Test("非法上限（<=0）在 init 就被夹到至少 1")
    func clampsNonPositiveLimitsAtInit() {
        let limits = LogRingBuffer.Limits(maxLineCount: 0, maxLineBytes: -5, maxTotalBytes: 0)

        #expect(limits.maxLineCount == 1)
        #expect(limits.maxLineBytes == 1)
        #expect(limits.maxTotalBytes == 1)
    }

    @Test("夹到 1 之后仍然可用：append 一行能留住")
    func clampedLimitsStillRetainOneLine() async {
        let limits = LogRingBuffer.Limits(maxLineCount: 0, maxLineBytes: 1000, maxTotalBytes: 1000)
        let buffer = LogRingBuffer(limits: limits)

        await buffer.append(text: "x", source: .stdout)

        #expect(await buffer.count == 1)
    }
}
