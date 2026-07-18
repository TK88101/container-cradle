/// 复制密钥时要写进剪贴板的完整条目清单。**为什么它是个类型而不是两行内联代码**：
/// Day 11 之前 `SecretField` 只写 concealed 标记不写 plain text——出发点是「明文别进
/// 剪贴板历史」，结果是**任何粘贴目标都读不到**（`org.nspasteboard.ConcealedType` 是
/// nspasteboard.org 社区约定里的**附加标记**，没有任何 App 会把它当内容读），
/// 「复制」按钮 100% 无效且没有测试能红。把「剪贴板上必须同时有什么」钉成纯函数，
/// `ConcealedCopyPayloadTests` 才有靶子：谁再「加固」掉 plain text，测试立刻红。
///
/// 权衡（用户拍板，Day 11 bug 报告）：plain text 在场意味着不认这个约定的剪贴板工具
/// 会记录明文；认约定的（Paste 等主流管理器）会跳过。复制功能必须先是活的。
public enum ConcealedCopyPayload {

    /// 粘贴目标读的类型（`NSPasteboard.PasteboardType.string` 的 raw value）。
    public static let plainTextType = "public.utf8-plain-text"

    /// 剪贴板管理器认的「别记录我」标记（nspasteboard.org 社区约定）。
    public static let concealedMarkerType = "org.nspasteboard.ConcealedType"

    public struct Entry: Equatable, Sendable {
        public let type: String
        public let value: String

        public init(type: String, value: String) {
            self.type = type
            self.value = value
        }
    }

    /// 明文对应的完整剪贴板条目：plain text（可粘贴）+ concealed 标记（可被跳过）。
    public static func entries(for plaintext: String) -> [Entry] {
        [
            Entry(type: plainTextType, value: plaintext),
            Entry(type: concealedMarkerType, value: plaintext),
        ]
    }
}
