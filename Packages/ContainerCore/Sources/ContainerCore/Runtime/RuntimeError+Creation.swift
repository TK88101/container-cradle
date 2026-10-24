extension RuntimeError {

    /// 一次 create / clone **没有确定结果**（结果未知）或**本 App 没有发出**（挡下）。都不是运行时故障诊断，
    /// supervisor 路径不产生（Day 26 由三个顶层 case 收成嵌套，Plan 2026-10-23 §2.1）。
    ///
    /// 加 case 时：`FailureKind(from:)` 与 `RuntimeErrorPresentation.notFailedCreationText` 对本类型穷尽 switch，
    /// 编译器会逼你在那两处表态（分类、算不算失败）。别把它们改成一个 `.creation` 分支。
    public enum Creation: Equatable, Sendable {

        /// 等到超时也没等来结果，**操作可能仍会完成**（Day 24，Plan 2026-10-21 附录 B）。
        /// `XPCTimeout` 到点即返回、不等在途调用，上游的 create 还在跑——之后容器可能照样建出来。
        /// 与 `.operationFailed` 分开，界面才不会把「还在建」说成「失败」。
        ///
        /// - Parameter reason: 超时诊断串，只用于展示与日志，绝不用于分类。
        /// - Parameter pending: 能取回这次结果的操作身份（`ContainerRuntimeClient.awaitPendingCreation`）；
        ///   nil = 没有可等的东西（已取不回，或本来就不是 create / clone）。Day 25。
        case outcomeUnknown(reason: String, pending: CreationOperationID? = nil)

        /// 本 App 已有同名的 create / clone 结果未定，**这次没有发出**（Day 25，Plan 2026-10-22 §2.2）。
        /// 名字要一直挡到那次请求返回（或 App 重开）——放行就可能让两次请求争同一个名字。
        ///
        /// - Parameter name: 被占着的容器名，给用户看的。
        case inProgress(name: String)

        /// 本 App 已有 `limit` 个 create / clone 结果未定，**这次没有发出**（Day 25）。
        /// 客户端自我保护阈值，**不是**运行时故障诊断（codex R6-P2）。
        case limitReached(limit: Int)
    }
}
