import Foundation

/// 一个 volume。domain 侧的**唯一** volume 表示——上游的 `VolumeConfiguration` 到此为止（D1）。
///
/// ## 为什么带 `source`（Day 10 codex 裁决 8）
///
/// 删除防线的 fingerprint（`matchesIdentity`）需要它，确认 sheet 的影响面文案也要它——
/// 「同名重建」场景里 source 是最有价值的核对信息。driver/format/labels 仍不带：无消费者
/// （与 `Container` 不带 `startedAt` 同一条纪律）。
///
/// ## `usedBytes` 与 `sizeMaxBytes` 的语义（R7 的数据源）
///
/// - `sizeMaxBytes` = 稀疏上限（本机 512 GiB），**不是真实占用**——单独展示它正是
///   R7 的恐慌源（用户以为磁盘满了，恐慌删卷）。
/// - `usedBytes` = 真实分配字节（XPC `volumeDiskUsage`，server 端递归
///   `totalFileAllocatedSize`）。`nil` = 没拿到（enrichment fail-soft：单卷超时/失败，
///   或 identity-only 路径刻意不取）。UI 层由 `VolumePresentation.sizeLabel` 保证
///   **永远双数**，nil 显示 "unknown" 而不是消失。
public struct Volume: Sendable, Equatable, Identifiable {

    public var id: String { name }

    public let name: String
    public let creationDate: Date
    public let source: String
    public let sizeMaxBytes: UInt64?
    public let usedBytes: UInt64?

    public init(
        name: String,
        creationDate: Date,
        source: String,
        sizeMaxBytes: UInt64?,
        usedBytes: UInt64?
    ) {
        self.name = name
        self.creationDate = creationDate
        self.source = source
        self.sizeMaxBytes = sizeMaxBytes
        self.usedBytes = usedBytes
    }

    /// R7 防线的判据：「同名卷还是不是确认时看到的那个卷」。
    ///
    /// 确认框开着的几十秒里，同名卷可能被外部删除重建——按名字删会删掉**新卷**。
    /// 所以删除前要用这个 fingerprint 复核（store 的 `verifying` 给 UX，
    /// live client 的 delete 内部复核是最后防线——DAY10-DEVPLAN ★R1/★R3）。
    ///
    /// **usedBytes / sizeMaxBytes 刻意不参与**：用量每秒都在漂，参与比较会让
    /// 「同一个卷、只是数据在写」被误判成「换了一个卷」。
    public func matchesIdentity(of other: Volume) -> Bool {
        name == other.name
            && creationDate == other.creationDate
            && source == other.source
    }
}
