/// 日志行的脱敏——**best-effort，已知值精确遮盖**，不是 `SecretString` 那种类型级保证
/// （`RedactedLogLine` 的类型文档写了同一句话，这里是它的实现）。
///
/// ## 为什么不能是类型级
///
/// 日志是自由文本，不是 `SecretString` 字段。没有类型能把「stdout 里某段字节恰好是密钥」
/// 标记出来——脱敏只能是「拿已知值去匹配」，而已知值集合本身可能不完整（容器把密钥
/// base64 / 拆行 / 变形后打出来，这里就遮不住）。
///
/// ## 为什么只遮已知值，不做模式猜测
///
/// `KEY=...` 之类的模式有无穷变体：`export KEY=`、`--key=`、JSON 里的 `"key":"..."`……
/// 每加一种能再漏一种，而漏的时候看起来和「没有密钥」一模一样。**只遮我们确知的值**，
/// 失败开放好过失败关闭到一半——不遮 = 明确的已知缺口，误以为遮了 = 更危险的假象。
public enum LogRedactor {

    /// 短于这个长度的值不参与匹配。空串、单字符若拿去匹配，会把日志里所有该字符
    /// 全部遮成噪音（比如某容器的密钥恰好是 `"1"`）——那样的「脱敏」比不脱敏更没用。
    public static let minimumSecretLength = 4

    /// 把 `knownSecrets` 准备成替换用的候选列表：取明文、按最短长度过滤、**按长度降序排序**
    /// （P1-3，codex review 定案：先替长的密钥再替短的，否则短密钥 `"abc"` 先把自己替换掉，
    /// 长密钥 `"abcdef"` 就再也匹配不到，输出里会留下 `<redacted>def` 这样的明文尾巴）。
    ///
    /// **C4：拆出来供调用方预计算一次。** 这份候选在一次 follow 会话里从头到尾不变
    /// （`knownSecrets` 是打开日志窗口那一刻从 `ContainerListStore` 查出来的快照），
    /// 而 `redact` 在 `LogTailer` 的 drain 循环里**每一行**都要调——不拆出来的话，
    /// 每行都要重新 map + filter + sort 同一份 `knownSecrets`。
    public static func candidates(from knownSecrets: [SecretString]) -> [String] {
        knownSecrets
            .map { $0.reveal() }
            .filter { $0.count >= minimumSecretLength }
            .sorted { $0.count > $1.count }
    }

    /// 把 `text` 里出现的 `knownSecrets`（该容器 `[EnvironmentVariable]` 里 `SecretString`
    /// 的明文）替换成 `<redacted>`。**一次性调用**（不打算复用候选列表）的便捷入口——
    /// 内部每次都重新 `candidates(from:)`。生产热路径（`LogTailer`）改走
    /// `redact(_:candidates:)`，自己预计算一次候选。
    ///
    /// 空集合法（该容器本就没有密钥，日志天然安全）→ 原样返回，不是错误。
    public static func redact(_ text: String, knownSecrets: [SecretString]) -> String {
        redact(text, candidates: candidates(from: knownSecrets))
    }

    /// 瘦身版：候选已经算好（降序长度、已经过滤短值），直接逐个替换，不重新准备。
    public static func redact(_ text: String, candidates: [String]) -> String {
        guard !candidates.isEmpty else { return text }

        var result = text
        for candidate in candidates {
            result = result.replacingOccurrences(of: candidate, with: SecretString.redactedPlaceholder)
        }
        return result
    }
}
