import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// `LiveContainerRuntimeClient.followLogs`——桥的接线（T6'）。
///
/// `LogFollowingTests.swift` 已经守住了纯逻辑（行装配、该不该结束流）；这里守的是
/// **接线本身**：XPCTimeout 有没有真的包住 setup、fd 有没有在 success/cancel/error
/// 三路都被关掉、越界形状有没有被响亮地拒绝。用真实的 `Pipe` 而不是 mock FileHandle——
/// `FileHandle` 是 Foundation 的 concrete 类型，"可观测的假 FileHandle" 用 `Pipe()` 造最直接。
///
/// ## fd 检查的一条纪律：先关写端，再问「读端关了没」
///
/// `isClosed(_:)`（见 `FileDescriptorTesting.swift`）靠尝试 `read` 来问一个 `FileHandle`
/// 有没有被关过。若读端其实**还开着**、也没有数据、写端**也还开着**，这次 `read`
/// 会阻塞到有数据或写端关闭为止——那会把「验证有没有关」变成「测试自己先卡死」。
/// 于是这里每个检查前都先把对应的写端关掉：读端若已被实现关闭，`read` 立刻抛错；
/// 若还没关，`read` 立刻拿到 EOF（空 `Data`，不抛错），两种情况都不会阻塞。
@Suite("LiveContainerRuntimeClient.followLogs：fd 接线与超时")
struct LiveContainerRuntimeClientLogsTests {

    private func client(
        upstream: FakeUpstreamClient,
        prober: FakeRuntimeProber = .up,
        timeout: Duration = .seconds(5)
    ) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: prober,
            timeout: timeout
        )
    }

    private func id(_ raw: String) throws -> ContainerID {
        try #require(ContainerID(raw))
    }

    // MARK: - P1-7：setup 调用套 XPCTimeout

    /// **不可取消的挂死**（`withUnsafeContinuation { _ in }`）——`Task.sleep` 测不出这个坑：
    /// 它响应取消，会让一个根本没有超时能力的实现也测出绿灯（CLAUDE.md 的教训，T6' DoD 明确要求）。
    @Test("upstream.logs 挂死 → followLogs 仍在超时后返回，不冻住", .timeLimit(.minutes(1)))
    func setupHangsButTimesOut() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setHangLogs(true)

        let subject = client(upstream: upstream, timeout: .milliseconds(20))

        await #expect(throws: RuntimeError.self) {
            _ = try await subject.followLogs(id: try id("cof-canary"))
        }
    }

    // MARK: - R14：建流失败也走进程表判定

    @Test("upstream.logs 失败 + prober 说 down → .runtimeUnavailable")
    func setupFailureWithDeadRuntimeMapsToRuntimeUnavailable() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailLogs(FakeUpstreamClient.Failure(label: "XPC connection invalid"))

        let subject = client(upstream: upstream, prober: .down)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            _ = try await subject.followLogs(id: try id("cof-canary"))
        }
    }

    // MARK: - 防御：上游形状变了不许崩

    /// 上游约定 `logs(id:)` 返回 `[stdio, boot]`；万一哪天只给一个（无 API 稳定性承诺，R1），
    /// 越界下标会崩掉整个 supervisor。必须响亮地失败，而且**已经拿到的 fd 不能泄漏**。
    @Test("upstream.logs 只返回一个 FileHandle → 响亮失败，且那个 fd 被关闭")
    func malformedHandleCountFailsLoudlyAndClosesWhatItGot() async throws {
        let pipe = Pipe()
        try? pipe.fileHandleForWriting.close()   // 不需要写端；先关掉，isClosed 才不会阻塞

        let upstream = FakeUpstreamClient()
        await upstream.setLogsResult("cof-canary", [pipe.fileHandleForReading])

        let subject = client(upstream: upstream)

        await #expect(throws: RuntimeError.self) {
            _ = try await subject.followLogs(id: try id("cof-canary"))
        }

        #expect(isClosed(pipe.fileHandleForReading), "拿到的那一个 fd 不该泄漏")
    }

    // MARK: - fd 生命周期：三路都要关

    /// boot log（`fhs[1]`）明确不接——必须在 setup 完成后**立刻**关闭，不等流终止
    /// （codex review P1-6：不然每次 follow 都泄漏一个 fd）。
    @Test("拿到 handles 后立刻关闭 boot fd，不等流被消费或取消")
    func closesBootHandleImmediately() async throws {
        let stdio = Pipe()
        let boot = Pipe()
        try? boot.fileHandleForWriting.close()   // boot 从不写数据；先关写端，isClosed 才不会阻塞

        let upstream = FakeUpstreamClient()
        await upstream.setLogsResult("cof-canary", [stdio.fileHandleForReading, boot.fileHandleForReading])

        let subject = client(upstream: upstream)
        let stream = try await subject.followLogs(id: try id("cof-canary"))

        #expect(isClosed(boot.fileHandleForReading), "boot fd 应该在 followLogs 返回时就已经关闭")

        // 清理：别让 stdio 的 readabilityHandler 悬在那儿影响别的测试。
        var iterator = stream.makeAsyncIterator()
        let consumer = Task { _ = try? await iterator.next() }
        consumer.cancel()
        try? stdio.fileHandleForWriting.close()
    }

    /// codex review P2：上游若哪天多返回一个 fd（形状扩了，无 API 稳定性承诺 R1），
    /// 只关 `handles[1]` 会把多出来的 fd 泄漏掉。stdio 之外的**每一个** handle 都要关。
    @Test("upstream.logs 返回多于 [stdio, boot] → stdio 之外的每个 fd 都被关闭")
    func closesEverySurplusHandleNotJustBoot() async throws {
        let stdio = Pipe()
        let boot = Pipe()
        let surplus = Pipe()
        try? boot.fileHandleForWriting.close()      // 先关写端，isClosed 才不会阻塞
        try? surplus.fileHandleForWriting.close()

        let upstream = FakeUpstreamClient()
        await upstream.setLogsResult(
            "cof-canary",
            [stdio.fileHandleForReading, boot.fileHandleForReading, surplus.fileHandleForReading]
        )

        let subject = client(upstream: upstream)
        let stream = try await subject.followLogs(id: try id("cof-canary"))

        #expect(isClosed(boot.fileHandleForReading), "boot fd 应在 followLogs 返回时已关闭")
        #expect(isClosed(surplus.fileHandleForReading), "多出来的第三个 fd 也必须被关闭，不能泄漏")

        // 清理：stdio 仍被流持有，收尾掉。
        var iterator = stream.makeAsyncIterator()
        let consumer = Task { _ = try? await iterator.next() }
        consumer.cancel()
        try? stdio.fileHandleForWriting.close()
    }

    /// 写进 stdio 管道的字节，经桥吐成 `LogLine`。
    @Test("stdio 管道里的字节被跟随并吐成 LogLine")
    func stdioBytesAreYieldedAsLogLines() async throws {
        let stdio = Pipe()
        let boot = Pipe()

        let upstream = FakeUpstreamClient()
        await upstream.setLogsResult("cof-canary", [stdio.fileHandleForReading, boot.fileHandleForReading])

        let subject = client(upstream: upstream)
        let stream = try await subject.followLogs(id: try id("cof-canary"))

        var iterator = stream.makeAsyncIterator()
        stdio.fileHandleForWriting.write(Data("apiserver ready\n".utf8))

        let first = try await iterator.next()
        #expect(first?.text == "apiserver ready")

        try? stdio.fileHandleForWriting.close()
    }

    /// **取消消费 → `onTermination` 必须把 stdio 关掉**（L6：不然取消路径悄悄泄漏 fd）。
    @Test("消费者取消 → stdio fd 最终被关闭", .timeLimit(.minutes(1)))
    func cancellingConsumerClosesStdioHandle() async throws {
        let stdio = Pipe()
        let boot = Pipe()

        let upstream = FakeUpstreamClient()
        await upstream.setLogsResult("cof-canary", [stdio.fileHandleForReading, boot.fileHandleForReading])

        let subject = client(upstream: upstream)
        let stream = try await subject.followLogs(id: try id("cof-canary"))

        let consumer = Task {
            for try await _ in stream {}
        }
        // 给它一点时间真的开始消费（装上 readabilityHandler），再取消。
        try? await Task.sleep(for: .milliseconds(20))
        consumer.cancel()

        // 没有数据要喂了——关掉写端，让接下来的 isClosed 检查永远不会阻塞
        // （不管 onTermination 有没有已经关掉读端，写端一关，读端上的 read 立刻返回）。
        try? stdio.fileHandleForWriting.close()

        await waitUntil { isClosed(stdio.fileHandleForReading) }
        #expect(isClosed(stdio.fileHandleForReading), "取消之后 stdio fd 必须被关闭，否则就是泄漏")
    }

    /// **L1'：写端关闭（EOF）→ 空读 → 管道不可 seek → 流以 RuntimeError 结束**，
    /// 不静默假装还在跟随。同时验证 fd 在流结束后被关闭（error 路径同样要关）。
    @Test("stdio 写端关闭 → seekToEnd 在管道上失败 → 流以 RuntimeError 结束，fd 被关闭", .timeLimit(.minutes(1)))
    func writeEndClosingEndsStreamWithError() async throws {
        let stdio = Pipe()
        let boot = Pipe()

        let upstream = FakeUpstreamClient()
        await upstream.setLogsResult("cof-canary", [stdio.fileHandleForReading, boot.fileHandleForReading])

        let subject = client(upstream: upstream)
        let stream = try await subject.followLogs(id: try id("cof-canary"))

        // 立刻关掉写端：读端会收到 EOF（空读），而管道不可 seek——seekToEnd 必然失败。
        try stdio.fileHandleForWriting.close()

        var caught: (any Error)?
        do {
            for try await _ in stream {}
        } catch {
            caught = error
        }

        let runtimeError = try #require(caught as? RuntimeError, "流结束的错误必须已经是 RuntimeError（D-A'）")
        guard case .operationFailed = runtimeError else {
            Issue.record("期望 .operationFailed，得到 \(runtimeError)")
            return
        }

        await waitUntil { isClosed(stdio.fileHandleForReading) }
        #expect(isClosed(stdio.fileHandleForReading), "结束流之后 stdio fd 也必须被关闭")
    }
}
