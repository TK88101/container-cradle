import Foundation
import Testing

@testable import ContainerCore

/// **R5 的可执行证明。** XPC 对端挂死时 `await` 永不返回——会冻住整个轮询循环，
/// supervisor 当场变瞎（而进程还活着、日志还在滚、看不出任何异常）。
///
/// ## 这里的测试装置刻意「不响应取消」
///
/// 顺手的写法是让假操作 `try await Task.sleep(for: .seconds(3600))`。**那会掩盖真正的 bug**：
/// `Task.sleep` 是可取消的，于是一个用 `withThrowingTaskGroup { group.addTask { try await work.value } }`
/// 写的、**根本没有超时能力**的实现，也能让这条测试变绿——因为 `cancelAll()` 唤醒了 sleep。
///
/// 而真实的 XPC 挂死**不响应取消**（对端不回包，Foundation 也不会替你 throw）。这时
/// `await work.value` 不是可取消的挂起点，task group 会一直等下去，超时形同虚设。
///
/// → 假操作用 `withUnsafeContinuation { _ in }`：永不 resume、永不响应取消。
/// **这是唯一能把「假超时」照红的装置。**
@Suite("XPCTimeout：对端挂死时必须能脱身")
struct XPCTimeoutTests {

    /// 永不返回、且**不响应取消**的操作——真实 XPC 挂死的忠实模型。
    private static func hangForever() async -> Int {
        await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
    }

    @Test("正常返回：值原样穿过")
    func passesValueThrough() async throws {
        let value = try await XPCTimeout.race(after: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("操作抛错：错误原样穿过，不被包成超时")
    func passesErrorThrough() async {
        struct Boom: Error, Equatable {}

        await #expect(throws: Boom.self) {
            try await XPCTimeout.race(after: .seconds(5)) { throw Boom() }
        }
    }

    /// ★ **这条是 R5 的核心。** 操作永不返回且不响应取消，`race` 仍必须在超时后返回。
    ///
    /// 实现若是「task group 等子任务」，这条测试会**挂住直到超时**——正是想要的红。
    @Test("对端挂死（不响应取消）：仍在超时后脱身", .timeLimit(.minutes(1)))
    func escapesUnresponsiveHang() async {
        await #expect(throws: XPCTimeout.TimedOut.self) {
            try await XPCTimeout.race(after: .milliseconds(20)) {
                await Self.hangForever()
            }
        }
    }

    /// 超时后必须**取消**那个 Task。取消不保证它会停（XPC 可能不理），
    /// 但不发取消信号，连响应取消的操作都会被白白泄漏。
    @Test("超时后：操作的 Task 收到取消信号")
    func cancelsOperationOnTimeout() async throws {
        let cancelled = Signal()

        await #expect(throws: XPCTimeout.TimedOut.self) {
            try await XPCTimeout.race(after: .milliseconds(20)) {
                // 可取消的 hang：收到取消 → 记下来。
                try? await Task.sleep(for: .seconds(60))
                await cancelled.fire()
                return 0
            }
        }

        // 等那个副作用**真的**发生，而不是 sleep 一下猜它发生了
        // （「断言副作用 = 跟调度器赛跑，必然假绿」——CLAUDE.md 已踩过的坑）。
        await cancelled.wait()
        #expect(await cancelled.fired)
    }

    /// ★ **codex review 抓到的 P2。**
    ///
    /// 进 `race` 时外层**已经**被取消 → `withTaskCancellationHandler` 会先跑 `onCancel`，
    /// 那时 continuation 还没装上。旧实现在这一格里什么都没做（`settle` 是 no-op 且不改状态），
    /// 于是 body 随后照常装上 continuation、照常开始等待——**那个取消凭空消失了**，
    /// 调用方明明取消了，却还要陪着等操作或超时。
    ///
    /// 装置说明：`Signal` 让被测任务**先被取消、再进入 `race`**，从而稳定命中这一格。
    /// 不修的话，这条测试会一直等到 60 秒超时——挂到 `.timeLimit` 才红。
    @Test("进来时已被取消 → 立刻抛 CancellationError，不等操作也不等超时", .timeLimit(.minutes(1)))
    func throwsImmediatelyWhenEnteredAlreadyCancelled() async {
        let proceed = Signal()

        let task = Task {
            await proceed.wait()                    // 等测试先把我 cancel 掉
            // 此刻 Task.isCancelled == true，race 是在已取消状态下进入的。
            return try await XPCTimeout.race(after: .seconds(60)) {
                await Self.hangForever()
            }
        }

        task.cancel()
        await proceed.fire()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    /// 超时时长必须原样带出来：给用户看的文案要说清「等了多久才放弃」。
    @Test("TimedOut 携带超时时长")
    func timedOutCarriesDuration() async {
        do {
            _ = try await XPCTimeout.race(after: .milliseconds(20)) {
                await Self.hangForever()
            }
            Issue.record("应当抛出 TimedOut")
        } catch let error as XPCTimeout.TimedOut {
            #expect(error.after == .milliseconds(20))
        } catch {
            Issue.record("抛出了意料之外的错误：\(error)")
        }
    }
}

/// 一次性信号量。测试要等一个**异步副作用**真的发生，而不是靠 sleep 猜它发生了。
private actor Signal {
    private(set) var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
