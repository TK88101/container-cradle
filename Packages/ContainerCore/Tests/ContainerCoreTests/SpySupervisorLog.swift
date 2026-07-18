import Foundation

@testable import ContainerCore

/// 记下 supervisor 每一次决策日志调用的 spy。**让「该记的记了」变成一个可断言的命题。**
///
/// 每个 case 的关联值都是 domain 值类型且 `Equatable` → 测试能精确断言「记了什么」。
///
/// P1-4 纪律：**只在锁下 append，不触发任何回调**。`SupervisorLog` 的方法从 `Supervisor.handle`
/// 的同步路径里被调用，spy 若在这里回调 / 阻塞就会破坏「handle 无重入窗口」这条不变式。
enum SupervisorLogEntry: Equatable, Sendable {
    case transition(from: SupervisorState, to: SupervisorState)
    case userForcedReconcile
    case reconcileStarted(RuntimeGeneration)
    case reconcileOutcome(ReconcileOutcome, RuntimeGeneration)
    case notice(SupervisorNotice)
    case containerStartFailed(ContainerID, RuntimeGeneration, RuntimeError)
}

final class SpySupervisorLog: SupervisorLog, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [SupervisorLogEntry] = []

    var entries: [SupervisorLogEntry] { lock.withLock { storage } }

    private func append(_ entry: SupervisorLogEntry) {
        lock.withLock { storage.append(entry) }
    }

    func transition(from: SupervisorState, to: SupervisorState) {
        append(.transition(from: from, to: to))
    }

    func userForcedReconcile() {
        append(.userForcedReconcile)
    }

    func reconcileStarted(generation: RuntimeGeneration) {
        append(.reconcileStarted(generation))
    }

    func reconcileOutcome(_ outcome: ReconcileOutcome, generation: RuntimeGeneration) {
        append(.reconcileOutcome(outcome, generation))
    }

    func notice(_ notice: SupervisorNotice) {
        append(.notice(notice))
    }

    func containerStartFailed(id: ContainerID, generation: RuntimeGeneration, error: RuntimeError) {
        append(.containerStartFailed(id, generation, error))
    }
}
