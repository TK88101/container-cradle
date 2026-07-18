/// app 可见的、已过 `LogRedactor` 遮蔽的日志行。**唯一由 `LogTailer` 产出的类型**——
/// app 层不构造它，只读它（`LogRingBuffer.snapshot()`）。
///
/// ## ★ 诚实标注：这不是类型级保证，是 best-effort（P0-1 裁决要求）
///
/// `SecretString` 那种「明文写不出来」的保证只对**已知字段**成立——值本身就是密钥，
/// 类型堵住的是*被动*泄漏渠道（插值、`description`、反射……）。
///
/// 日志是**自由文本**，没有类型能标出「stdout 里某段字节恰好是密钥」。`LogRedactor`
/// 只替换**已知密钥的明文值**（该容器 `[EnvironmentVariable]` 里 `SecretString` 的 `reveal()`）；
/// 容器若把密钥 base64 编码、拆成多行、做了任何变形再打出来，残余明文会原样出现在 `text` 里。
/// 这是**已知、已接受的缺口**（Day 9 计划 D-B'），不是疏忽——不允许把这条注释删掉再假装
/// `RedactedLogLine` 和 `SecretString` 一样可靠。
///
/// 与 `SecretString` 的边界类比：`SecretString` 靠类型**堵死**被动渠道，堵不住的渠道不存在；
/// 这里靠**写入 ring buffer 之前主动扫一遍已知值**，扫描本身可能漏过未知形态的明文。
/// 两者的可靠性不在同一个量级，别混为一谈。
public struct RedactedLogLine: Sendable, Equatable, Identifiable {

    /// `LogRingBuffer` 维护的单调递增序号。清屏之后的新行序号不回绕——
    /// UI（`ForEach(id: \.id)`）靠它稳定区分「清屏前的旧内容」与「清屏后的新内容」。
    public let id: Int

    /// 已遮蔽文本。**不保证零残余明文**——见类型文档。
    public let text: String

    public let source: LogStreamKind

    public init(id: Int, text: String, source: LogStreamKind) {
        self.id = id
        self.text = text
        self.source = source
    }
}
