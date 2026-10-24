import ContainerCore
import Synchronization

/// **create / clone 的在途登记处**（Day 25，Plan 2026-10-22 §2.2，codex 7 轮定稿）。
///
/// `XPCTimeout` 到点就返回、不等在途调用（R5 的既定取舍）——create 超时之后，上游那次调用还在跑，
/// 之后可能照样把容器建出来。这里持有那次调用，让两件事成为可能：
///
/// 1. **同名挡住**（G-C）：同一个 App 里同名创建同时只许一个在途；后来者**不调上游**。
/// 2. **取回真实结果**（G-A / G-D）：超时后按 `CreationOperationID` 等**那一次**的结果——
///    拿到成功才算成功，「创建并启动」才敢补上启动。
///
/// ## 两张表，不能合成一张（codex R3-P1）
///
/// `reservations`（名字 → operationID）只管互斥；`operations`（operationID → 在途 / 结果）只管取结果。
/// 合成按名字的一张时，A 完成后同名的 B 一占名就覆盖掉 A 的待领结果，A 拿着自己的 id 也找不回来。
///
/// ## 不用 generation（codex R5-P1）
///
/// 占名时观测到的 apiserver 代，不是这次调用最终打到的那一代——fresh create 先在客户端 fetch 镜像，
/// fetch 期间换代，之后照样向新的一代发 create。拿观测值判「旧调用已失效」没有证据，所以名字**只随那次调用结束释放**。
///
/// ## 线性化（codex R6-P1）
///
/// 占名、建 Task、登记在**同一个临界区**里完成；Task 的收尾要拿同一把锁，只能排在登记之后。
/// 同一 operationID 上的 await / abandon / 收尾，谁先拿到锁谁说了算。
final class CreationCoordinator: Sendable {

    typealias Outcome = Result<ContainerID, RuntimeError>

    /// 同时在途（结果未定）的创建数上限。**客户端自我保护阈值**，不是运行时故障诊断（codex R6-P2）。
    static let maxConcurrentCreations = 8

    /// 无人领取的结果最多留这么多条，超出淘汰最早完成的。来源只有「主人预算到期收尾之后才完成」的那一小段。
    static let maxRetainedOutcomes = 16

    enum AwaitResult: Equatable, Sendable {
        /// 这一次的真实结果，已交出并从表里删掉。
        case delivered(Outcome)
        /// 预算内仍没结果，或等的人被取消了。条目还在，可以再等。
        case stillRunning
        /// 结果已取不回：被取走了、被放弃了、被淘汰了，或者根本不是这里登记的。
        case unavailable
    }

    private enum Operation {
        case inFlight(Task<Outcome, Never>)
        case done(Outcome, seq: UInt64)
    }

    private struct State {
        var reservations: [String: CreationOperationID] = [:]
        var operations: [CreationOperationID: Operation] = [:]
        var nextSeq: UInt64 = 0
    }

    private let state = Mutex(State())

    /// 占名并启动 `work`（上游调用 + 错误映射，**只映射一次**——codex R2-P2）。
    ///
    /// - Throws: 同名在途 ⇒ `.creation(.inProgress)`；在途数到上限 ⇒ `.creation(.limitReached)`。两者都**不跑** `work`。
    ///
    /// 只交出 operationID，**不交出 Task**：唯一的取结果途径是有界的 `awaitOutcome`，
    /// 于是「无界地等上游」在调用方写不出来（R-HANG 守卫据此把 `coordinator.start` 的闭包视为有界）。
    func start(
        name: String,
        work: @escaping @Sendable () async -> Outcome
    ) throws(RuntimeError) -> CreationOperationID {
        try state.withLock { (state) throws(RuntimeError) -> CreationOperationID in
            // 同名先于上限：用户要知道的是「这个名字正在建」，而不是笼统的「太多了」。
            guard state.reservations[name] == nil else { throw .creation(.inProgress(name: name)) }
            guard state.reservations.count < Self.maxConcurrentCreations else {
                throw .creation(.limitReached(limit: Self.maxConcurrentCreations))
            }

            let operationID = CreationOperationID()
            state.reservations[name] = operationID
            // Task 体可能立刻在别的线程开跑，但 `finish` 要拿这把锁——只能排在下面这行登记之后。
            let task = Task {
                let outcome = await work()
                self.finish(operationID, name: name, outcome: outcome)
                return outcome
            }
            state.operations[operationID] = .inFlight(task)
            return operationID
        }
    }

    /// 最多等 `budget`，取回 `operationID` 那一次的结果。
    func awaitOutcome(_ operationID: CreationOperationID, within budget: Duration) async -> AwaitResult {
        let entry = state.withLock { $0.operations[operationID] }

        let outcome: Outcome
        switch entry {
        case nil:
            return .unavailable
        case .done(let finished, _):
            outcome = finished
        case .inFlight(let task):
            do {
                outcome = try await XPCTimeout.race(after: budget) { await task.value }
            } catch {
                return .stillRunning   // 超预算或调用方被取消：条目不动，可再等
            }
        }
        // 读到之后（尤其等的期间）可能已被 abandon / 被另一个 await 取走——锁内复查，不在了就不交（codex R6-P1）。
        return take(operationID) ? .delivered(outcome) : .unavailable
    }

    /// 主人宣告不再取结果。幂等。**不放开名字**——上游调用可能仍会建出容器（G-C）。
    func abandon(_ operationID: CreationOperationID) {
        take(operationID)
    }

    /// 测试与上界断言用。
    var counts: (reservations: Int, operations: Int, inFlight: Int) {
        state.withLock { state in
            let inFlight = state.operations.values.filter {
                if case .inFlight = $0 { true } else { false }
            }.count
            return (state.reservations.count, state.operations.count, inFlight)
        }
    }

    // MARK: - 收尾 / 取走

    /// 那次调用结束：放开名字；若主人还没领（仍登记着），把结果存成待领。
    private func finish(_ operationID: CreationOperationID, name: String, outcome: Outcome) {
        state.withLock { state in
            // 名字只会是自己的（从不覆盖）；仍按 id 校验，防实现走样。
            if state.reservations[name] == operationID { state.reservations[name] = nil }

            guard case .inFlight = state.operations[operationID] else { return }   // 已被放弃 / 已被取走：丢弃
            state.operations[operationID] = .done(outcome, seq: state.nextSeq)
            state.nextSeq &+= 1
            Self.evictOldestDoneIfNeeded(&state)
        }
    }

    /// 锁内取走一条登记；返回它刚才是否还在。await 的交付与 abandon 都走这里，谁先拿到锁谁赢。
    @discardableResult
    private func take(_ operationID: CreationOperationID) -> Bool {
        state.withLock { $0.operations.removeValue(forKey: operationID) != nil }
    }

    private static func evictOldestDoneIfNeeded(_ state: inout State) {
        let done = state.operations.compactMap { id, operation -> (id: CreationOperationID, seq: UInt64)? in
            if case .done(_, let seq) = operation { (id, seq) } else { nil }
        }
        guard done.count > maxRetainedOutcomes, let oldest = done.min(by: { $0.seq < $1.seq }) else { return }
        state.operations[oldest.id] = nil
    }
}
