import Foundation

/// 一次 create / clone 的**操作身份**（Day 25，Plan 2026-10-22 §2.2）。
///
/// 超时后要取回「这一次」的真实结果，凭的是它而不是容器名：名字是公开的、可以被同名的下一次提交重新占用，
/// 按名字取结果会把别人那次的结果交给你（codex R2-P0）。它只经由本次 create 抛出的
/// `.creation(.outcomeUnknown(reason:pending:))` 交到调用方手里，别处换不出来。
///
/// 不含任何容器数据（D2 无关）；日志只记 case 名，不记它。
public struct CreationOperationID: Hashable, Sendable {

    private let value: UUID

    public init() {
        value = UUID()
    }
}
