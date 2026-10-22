/// create / clone 超时后的「确认段」——两个 store 同形，抽成一处（Day 25，Plan 2026-10-22 §2.3）。
///
/// 凭 create 抛出的 operationID 取回**那一次**的真实结果；预算内仍没结果就**放弃取回**（所有权结束，
/// 名字仍由 runtime 挡到上游调用返回），终态 `.outcomeUnknown` 不再带 operationID——没有人会再去取它。
enum PendingCreationConfirmation {

    /// UX 等待预算，**不是完成保证**（codex R1-P1）：create 已等过 300 s，再等至多这么久。
    static let budget: Duration = .seconds(300)

    static func confirm(
        _ operationID: CreationOperationID,
        client: any ContainerRuntimeClient
    ) async -> Result<ContainerID, RuntimeError> {
        do {
            return .success(try await client.awaitPendingCreation(operationID, within: budget))
        } catch {
            guard case .outcomeUnknown(let reason, let pending?) = error else { return .failure(error) }
            await client.abandonPendingCreation(pending)
            return .failure(.outcomeUnknown(reason: reason, pending: nil))
        }
    }
}
