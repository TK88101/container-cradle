import Foundation

/// App 退出前的**有界**交接（R2 F → R4 F）：先把白名单写入链排空，再交接给 supervisor（探一次 + 等在途的 reconcile），
/// 两段共用**一个**总预算。
///
/// - 写入链排在前面：settle 触发的 reconcile 读的是磁盘上的白名单（`WhitelistStore`），刚勾选的那次写得先落地。
/// - 写入链本身可能卡在文件系统上（网络家目录）：`awaitWrites` 原来没有上限，退出会被它永远冻住——这里给它套上
///   `XPCTimeout.race`（continuation + 不等：挂死的等待泄漏掉）。超时 ⇒ 不再 settle（预算已尽；reconcile 会读到过时的白名单），
///   那次写被放弃（本来也完不成）。调用方按返回值记日志。
///
/// 纯编排、住 core：app target 没有测试 target，放那儿这段「有界」一行测试都跑不了。
public enum QuitHandOff {

    public enum Outcome: Sendable, Equatable {
        case completed
        /// 白名单写入链在预算内没排空（没有做 settle）。
        case writesTimedOut
        /// 写入链排空了，交接给 supervisor 没在剩余预算内完成。
        case settleTimedOut
    }

    /// - Parameters:
    ///   - awaitWrites: 排空白名单写入链（生产上 = `WhitelistUIStore.awaitWrites`，无上限）。
    ///   - settle: 以给定的剩余预算交接给 supervisor；返回是否按时交接完（生产上 = `Supervisor.settleBeforeStop(within:)`，自身有界）。
    public static func run(
        budget: Duration,
        awaitWrites: @escaping @Sendable () async -> Void,
        settle: @Sendable (Duration) async -> Bool
    ) async -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await XPCTimeout.race(after: budget) { await awaitWrites() }
        } catch {
            return .writesTimedOut
        }
        let remaining = budget - start.duration(to: clock.now)
        guard remaining > .zero else { return .settleTimedOut }
        return await settle(remaining) ? .completed : .settleTimedOut
    }
}
