import Foundation

/// 该容器脱敏所需的密钥集合有没有解析出来。**三态，不是两态**（D-B'，P0-1 裁决）。
///
/// `.resolved(secrets: [])`（空集）与「没解析出来」是两码事，绝不能合并：
/// 前者是「这个容器本就没有密钥，日志天然安全」（合法状态，正常 follow）；
/// 后者是「不知道有没有密钥」（`ContainerListStore` 还没加载完，或这个 ID 已经不在列表里）——
/// 这时候唯一诚实的做法是 **fail closed**：宁可不显示日志，也不能在不确定的情况下假设「没有密钥」
/// 然后把可能的明文原样糊到屏幕上。
public enum RedactionContext: Sendable, Equatable {
    case resolved(secrets: [SecretString])
    case unresolved
}

/// `LogTailer` 对外暴露的状态，供 UI 决定显示什么（日志内容 / 降级横幅 / 「已过期」提示）。
public enum LogTailerStatus: Sendable, Equatable {

    /// `RedactionContext` 是 `.unresolved` 时的状态：**没有建立 follow，也没有消费任何行**。
    case unresolved

    case following

    /// 上游流结束了（正常关闭，或抛错）。`reason` 是错误的人话描述，`nil` 表示正常结束。
    /// **不代表「容器停了」**——也可能只是这次 follow 连接本身失效，具体判断留给上层。
    case streamEnded(reason: String?)
}

/// 编排「消费裸 `LogLine` 流 → 脱敏 → 写进有界 ring buffer」的 actor。
/// **裸 `LogLine` 流唯一被允许的消费者**（`BoundaryScanner` 的源码扫描钉死这条，见 `D1BoundaryTests`）。
///
/// ## 暂停是 view 层概念，这里没有「停止消费」这条路（D-C'，P1-1 裁决）
///
/// 直觉的实现是「暂停 = 不再从流里读」。**这是陷阱**：`AsyncThrowingStream` 的默认缓冲无界，
/// chatty 容器在用户暂停的那几分钟里会把流内部的缓冲撑爆——「暂停」反而制造了 P1-1 想防的
/// 那种无界增长。这里的形状是**永远 drain**：不管 UI 是不是暂停了，行照样被消费、脱敏、
/// 写进有界 ring buffer（超了就丢最旧）。「暂停」在 view 层的意思是「冻结自动滚动/快照刷新」，
/// 不是「不读」——这个类型上没有开关能让它变成「不读」。
///
/// ## 为什么 `redaction` 是必填的构造参数，不是可选/后设
///
/// 「跟着日志但不脱敏」在这个类型上必须写不出来。`.unresolved` 不是「先跟着、回头再脱敏」，
/// 而是**根本不建立 drain**——`status` 停在 `.unresolved`，ring buffer 永远是空的。
///
/// ## 为什么 `status` 住在一个锁保护的盒子里，不是普通的 actor 存储属性
///
/// drain Task 要在流结束/出错时回写 `status`。若它直接捕获 `self` 去调用一个 actor-isolated
/// 方法，Swift 6 的 actor 初始化隔离规则会拒绝：一个捕获了 `self` 的逃逸闭包**之后**，
/// `init` 不能再同步写别的 actor-isolated 存储属性（连给 `drainTask` 这次赋值本身都不行——
/// 实测编译器报 "cannot access property 'drainTask' here in nonisolated initializer"）。
/// 绕开的办法是「引导 Task 二次跳转到普通方法」，但那样 `init` 返回后到 drain 真正装上之间
/// 会多一个 `await` 窗口——`cancel()` 能插进那个窗口，得再补一个「记下 cancel、让装配那刻
/// 自己发现」的标记才补得平，徒增一层没有必要的竞态。
///
/// 更干净的办法：drain Task **完全不捕获 `self`**——`status` 挪到 actor 之外，
/// 由一个锁保护的小盒子（`StatusBox`，同 `SpySupervisorLog` 的 `NSLock` 套路）持有。
/// 于是 `init` 里可以直接同步把 `drainTask` 装上，没有额外的调度跳转，也没有对应的竞态。
public actor LogTailer {

    /// 见类型文档「为什么 `status` 住在一个锁保护的盒子里」。
    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: LogTailerStatus

        init(_ value: LogTailerStatus) {
            self.value = value
        }

        func read() -> LogTailerStatus {
            lock.withLock { value }
        }

        func set(_ newValue: LogTailerStatus) {
            lock.withLock { value = newValue }
        }

        /// `.unresolved` 从未建立 drain，不该被一个理论上不可能出现的回调覆盖；
        /// 已经是 `.streamEnded` 的也不重复覆盖（第一个原因就是真实原因）。
        func markStreamEnded(reason: String?) {
            lock.withLock {
                guard value == .following else { return }
                value = .streamEnded(reason: reason)
            }
        }
    }

    private let statusBox: StatusBox
    private let ring: LogRingBuffer
    private var drainTask: Task<Void, Never>?

    public var status: LogTailerStatus { statusBox.read() }

    /// - Parameters:
    ///   - rawStream: 未脱敏的裸流。若 `redaction` 是 `.unresolved`，这个流**不会被消费**——
    ///     它在 `init` 返回后随局部参数释放（触发桥挂的 `onTermination(.cancelled)`，实测确认过：
    ///     一个从未被迭代的 `AsyncThrowingStream` 在作用域结束时会自动收到 `.cancelled`）。
    ///   - redaction: 见 `RedactionContext`。必填：构造不出「没有脱敏上下文的 tailer」。
    public init(
        rawStream: AsyncThrowingStream<LogLine, any Error>,
        redaction: RedactionContext,
        ring: LogRingBuffer = LogRingBuffer()
    ) {
        self.ring = ring

        guard case .resolved(let secrets) = redaction else {
            statusBox = StatusBox(.unresolved)
            return
        }

        let statusBox = StatusBox(.following)
        self.statusBox = statusBox

        // C4：候选列表（明文、已过滤、已按长度降序）在这一次 follow 会话里从头到尾不变——
        // 算一次，drain 循环里每一行复用，不必每行都重新 map/filter/sort 同一份 `secrets`。
        let candidates = LogRedactor.candidates(from: secrets)

        drainTask = Task { [ring, candidates] in
            do {
                for try await line in rawStream {
                    let redacted = LogRedactor.redact(line.text, candidates: candidates)
                    await ring.append(text: redacted, source: line.source)
                }

                // `cancel()` 会让这个循环以「正常结束」的形态退出（实测：Task 取消会让
                // `for try await` 优雅收尾，不抛错）。那是调用方主动收工，不是「流结束」——
                // 两者对 UI 的含义完全不同，不能混进同一个 `.streamEnded`。
                guard !Task.isCancelled else { return }
                statusBox.markStreamEnded(reason: nil)
            } catch {
                guard !Task.isCancelled else { return }
                statusBox.markStreamEnded(reason: String(describing: error))
            }
        }
    }

    // MARK: - 对外

    public func snapshot() async -> [RedactedLogLine] {
        await ring.snapshot()
    }

    public func clear() async {
        await ring.clear()
    }

    /// 硬收尾（窗口关闭时调）。**不清空已有内容**——用户可能还想看已经跟到的日志，
    /// 清不清屏是他自己按按钮决定的事，不是关窗的副作用。
    public func cancel() {
        drainTask?.cancel()
        drainTask = nil
    }

    /// 等 drain 彻底收工（有限的假流用完 / 出错 / 被 `cancel()`）。
    /// **只给测试用**——生产上没有调用方需要「等它跑完」，drain 本就是长驻的。
    /// 不给这个钩子，测试就只能睡一觉然后但愿它跑完了（CLAUDE.md 已踩过的坑：那种测试
    /// 在 CI 上必然间歇性红）。对一条「挂起」的流调用它会一直等下去——不要在那种测试里调它。
    public func awaitDrained() async {
        _ = await drainTask?.value
    }
}
