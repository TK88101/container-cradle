/// 哪一路输出产生的这一行。
///
/// M4 只用 `.stdout`（`fhs[0]`）：boot log（`fhs[1]`）明确不接（Day 9 计划 §1「明确不做」）。
/// 单独成 enum 而不是内联在 `LogLine` 里，是因为 `RedactedLogLine` 也要携带同一个字段——
/// 两处各自定义会在将来加 case（比如真的要接 boot log 那天）时漂成两套语义。
public enum LogStreamKind: Sendable, Equatable, CaseIterable {
    case stdout
}

/// 容器 stdout 的一条原始日志行——**未脱敏**。
///
/// ## D-B'：这不是 app 可达的 API
///
/// 它只在 ContainerRuntime 的 FileHandle→stream 桥与 core 的 `LogTailer` 之间流动；
/// `LogTailer` 是它**唯一**允许的消费者——`BoundaryScanner` 的新规则钉死这条
/// （`identifierUsages(in:identifier:"LogLine")`），越界即红（见 `D1BoundaryTests`）。
/// app 只看得到 `LogTailer` 产出的 `RedactedLogLine`。
///
/// ## 为什么没有时间戳
///
/// 与 `Container` 刻意没有 `startedAt` 同理（见该文件文档）：`readabilityHandler` 不按行
/// 提供时间戳，伪造一个只会制造「看起来精确、其实是编的」的假象，而且没有消费者要求它。
public struct LogLine: Sendable, Equatable {

    /// 未脱敏的原始文本。**不得穿过 D-B' 的边界**——见类型文档。
    public let text: String

    public let source: LogStreamKind

    /// 行序号，供桥/测试标记装配顺序；`nil` 表示调用方不关心。core 侧不依赖它做任何判断——
    /// `LogRingBuffer` 自己维护单调递增的 `RedactedLogLine.id`，不借用这个字段。
    public let sequence: Int?

    public init(text: String, source: LogStreamKind = .stdout, sequence: Int? = nil) {
        self.text = text
        self.source = source
        self.sequence = sequence
    }
}
