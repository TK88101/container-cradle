/// 容器的一条环境变量。**值恒为 `SecretString`——不区分「敏感」与「不敏感」。**
///
/// 不做启发式判断（比如「名字里有 KEY/TOKEN 才算密钥」）：那种名单永远漏，
/// 且漏的那次就是不可挽回的泄漏（CLAUDE.md R2）。一律当密钥处理，要看必须显式 `reveal()`。
///
/// 「PATH 也被打码很吵」是**展示**问题，须在 view 层用「默认展开哪些 key」的策略解决，
/// 绝不能下沉成类型层的「哪些算密钥」判断——那种判断会**失败开放**，而 R2 的失败不可挽回。
///
/// 不遵从 `Hashable`：见 `SecretString` 的同名说明（`hashValue` 是绕开脱敏的泄漏渠道）。
public struct EnvironmentVariable: Sendable, Equatable, Encodable {

    public let key: String
    public let value: SecretString

    public init(key: String, value: SecretString) {
        self.key = key
        self.value = value
    }

    /// 解析上游 `ProcessConfiguration.environment` 的单个元素（形如 `"KEY=VALUE"`）。
    ///
    /// **按首个 `=` 切分**：值可能是 base64，本身含 `=`（实测密钥就以 `=` 结尾）。
    /// 按最后一个或按全部切都会得到被截断的密钥，而且错得无声无息。
    ///
    /// 畸形输入（无 `=`、key 为空）返回 `nil` 而非崩溃——上游无 schema 承诺，
    /// mapper 必须能吞下意外输入（R1）。
    public init?(parsing raw: String) {
        guard let separator = raw.firstIndex(of: "=") else { return nil }

        let key = String(raw[raw.startIndex..<separator])
        guard !key.isEmpty else { return nil }

        let value = String(raw[raw.index(after: separator)...])
        self.init(key: key, value: SecretString(value))
    }
}
