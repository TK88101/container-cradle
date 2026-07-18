import Foundation
import Synchronization

/// **给每一个上游调用套一层硬超时。R5 的落点。**
///
/// XPC 对端挂死时 `await` **永不返回**。没有超时，它会冻住轮询循环——而进程还活着、
/// 菜单栏图标还在、日志还在滚：supervisor 变瞎了，且看不出任何异常。
///
/// ## 为什么不能用 `withThrowingTaskGroup`
///
/// 顺手的写法是「一个子任务干活，一个子任务 sleep，谁先回来算谁」：
///
/// ```swift
/// try await withThrowingTaskGroup(of: T.self) { group in
///     group.addTask { try await work.value }              // ← 这里
///     group.addTask { try await clock.sleep(for: t); throw TimedOut() }
///     defer { group.cancelAll() }
///     return try await group.next()!
/// }
/// ```
///
/// **它没有超时能力。** task group 在返回前会**等待全部子任务结束**，而 `await work.value`
/// **不是可取消的挂起点**——`cancelAll()` 唤不醒它。操作若真的挂死（这正是 R5 的场景），
/// 那个子任务永远不结束，group 永远不返回，超时形同虚设。
///
/// 更坏的是：拿 `Task.sleep` 当假操作去测它，**测试是绿的**（sleep 响应取消）。
/// 这个陷阱只有用「不响应取消的 hang」才照得出来——`XPCTimeoutTests` 就是那么写的。
///
/// ## 于是：continuation + **不等**
///
/// 超时到了就直接 resume，**不等那个操作**。它的 Task 会收到 `cancel()`，但 XPC 可能根本不理——
/// 那就让它挂在那儿泄漏掉。**宁可泄漏一个挂死的调用，也不能冻住 supervisor。**
/// 这是刻意的取舍，不是疏忽：挂死的 XPC 调用最终会随 apiserver 换代而消失，
/// 而冻住的 supervisor 会一直瞎到用户重启 App。
public enum XPCTimeout {

    /// 等了 `after` 这么久，对端还没回话。
    ///
    /// 刻意是**独立的错误类型**，不是 `RuntimeError`：本工具零 domain 耦合
    /// （它不知道什么是容器），映射成哪一档失败是调用方的事。
    /// live client 把它映射成 `.operationFailed` → `.transient` → 走退避（R5 明确要求：
    /// 超时**不**等于「运行时挂了」，那是 prober 的判断，不是超时的判断）。
    public struct TimedOut: Error, Equatable, Sendable {
        public let after: Duration

        public init(after: Duration) {
            self.after = after
        }
    }

    /// 跑 `operation`，超过 `timeout` 就抛 `TimedOut`。
    ///
    /// - 操作正常返回 / 抛错 → 原样穿过（错误**不**被包成超时）。
    /// - 超时 → 抛 `TimedOut`，并向操作发取消信号（不等它响应）。
    /// - 外层任务被取消 → 抛 `CancellationError`，同样不等操作。
    public static func race<T: Sendable>(
        after timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = Mutex<State<T>>(.fresh)

        // 在 continuation **之外**启动：`onCancel` 要够得着它。
        let work = Task<T, any Error> { try await operation() }

        /// 抢着结束这场比赛。**谁先抢到谁说了算，其余的调用是 no-op。**
        /// 三个来源会抢：操作完成、超时、外层取消。continuation 只能 resume 一次，
        /// 而这三者天然是并发的——判定与消费必须焊成一个原子操作，
        /// 「先查标记再 resume」在两步之间就会被插入（这个仓库已经栽在同一条上三次了）。
        ///
        /// ## `.fresh` 时抢到，必须留下痕迹
        ///
        /// `onCancel` 可能在 continuation 装上**之前**就打进来（进 `race` 时外层已经被取消了——
        /// `withTaskCancellationHandler` 那时会先跑 `onCancel`，body 还没执行）。
        ///
        /// 这时手里没有 continuation，resume 不了。但**不能就这么算了**：
        /// 若状态还留在 `.fresh`，随后 body 会照常装上 continuation、照常开始等待，
        /// 那个 `CancellationError` 就**凭空消失**了——调用方明明取消了，却还要等操作或超时。
        /// （codex review 抓到的：注释声称「推到 settled」，代码其实什么都没做。）
        ///
        /// → 记成 `.cancelledBeforeStart`，让 body 自己发现并立刻 resume。
        let settle: @Sendable (Result<T, any Error>) -> Void = { result in
            let continuation = state.withLock { current -> UnsafeContinuation<T, any Error>? in
                switch current {
                case .waiting(let continuation):
                    current = .settled
                    return continuation

                case .fresh:
                    // 只有 `onCancel` 够得到这一格：`work` 与计时器都是在 continuation
                    // 闭包**内部**启动的，它们跑起来时 continuation 一定已经装好了。
                    current = .cancelledBeforeStart
                    return nil

                case .cancelledBeforeStart, .settled:
                    return nil
                }
            }
            continuation?.resume(with: result)
        }

        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<T, any Error>) in
                // 外层可能**在 continuation 装好之前**就已被取消（进来时就是已取消状态 →
                // `withTaskCancellationHandler` 先跑 `onCancel`，body 还没轮到）。
                // 这里必须自己发现这件事，否则那个取消就被吞掉了。
                let cancelledEarly = state.withLock { current -> Bool in
                    switch current {
                    case .fresh:
                        current = .waiting(continuation)
                        return false
                    case .cancelledBeforeStart:
                        current = .settled
                        return true
                    case .waiting, .settled:
                        preconditionFailure("continuation resumed twice — impossible unless the race was reentered")
                    }
                }

                guard !cancelledEarly else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                Task {
                    do {
                        settle(.success(try await work.value))
                    } catch {
                        settle(.failure(error))
                    }
                }

                Task {
                    // `try?`：这个计时器自己被取消不是失败——只是没人再需要它了。
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }

                    work.cancel()
                    settle(.failure(TimedOut(after: timeout)))
                }
            }
        } onCancel: {
            work.cancel()
            settle(.failure(CancellationError()))
        }
    }

    private enum State<T: Sendable>: Sendable {
        /// continuation 还没装上（`onCancel` 有可能在这一刻就打进来）。
        case fresh

        case waiting(UnsafeContinuation<T, any Error>)

        /// ★ 取消在 continuation 装上之前就到了。
        ///
        /// 单列一格，而不是复用 `.settled`：`.settled` 的含义是「已经 resume 过了」，
        /// 而这里**一次都还没 resume**——body 拿到 continuation 后仍然必须 resume 一次
        /// （抛 `CancellationError`）。两件事混成一格，就得靠「只有 onCancel 会走到那里」
        /// 这种推理来保证正确性，而推理不会在代码改动时跟着更新。
        case cancelledBeforeStart

        /// 已经 resume 过了。后来者一律 no-op。
        case settled
    }
}
