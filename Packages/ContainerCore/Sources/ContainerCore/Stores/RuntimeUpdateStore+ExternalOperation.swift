import Foundation

/// 外部运行时操作的租约 token（Day 23，Plan 2026-09-29 §2.3）。只有 store 能造。
public struct ExternalRuntimeToken: Sendable, Equatable {
    let id = UUID()
}

/// 运行时自动启动（`RuntimeAutoStarter`）与更新器的互斥：更新器是另一个会起停运行时的人，两边同时动手就是两个启动者抢同一个运行时。
///
/// 刻意是**租约**而不是一个可写的 Bool（codex R1 #5）：核对与登记在这里同步焊成一步，释放只认匹配的 token、幂等——
/// starter 退出时要同步释放（它的 task 可能挂在不响应取消的 await 上，`defer` 永远到不了，codex R3），之后 task 若恢复再释放一次是 no-op。
extension RuntimeUpdateStore {

    /// 拿租约。忙、有待补的恢复 / 重启确认（补做优先，codex R2 a）、退出中、非主实例 ⇒ `nil`。
    public func tryBeginExternalRuntimeOperation() -> ExternalRuntimeToken? {
        guard isPrimaryInstance, !isTerminating, !isBusy else { return nil }
        guard deferredRecoveryNonce == nil, !restartCheckPending else { return nil }
        let token = ExternalRuntimeToken()
        externalOperation = token
        return token
    }

    /// 还租约。过期 / 重复的 token 是 no-op。之后补做持有期间被挡掉的恢复 / 重启确认（退出途中由它们各自的闸挡住）。
    public func endExternalRuntimeOperation(_ token: ExternalRuntimeToken) {
        guard externalOperation == token else { return }
        externalOperation = nil
        operationEnded()
    }
}
