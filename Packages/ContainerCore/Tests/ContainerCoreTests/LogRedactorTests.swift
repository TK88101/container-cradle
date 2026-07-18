import Testing

@testable import ContainerCore

/// `LogRedactor`：best-effort、已知值精确遮盖。**不是** `SecretString` 那种类型级保证——
/// 这里守的是「已知值一定被遮」，遮不住的未知形态是已接受的缺口（`RedactedLogLine` 的类型文档）。
@Suite("LogRedactor：已知密钥值精确遮盖")
struct LogRedactorTests {

    @Test("已知密钥值出现在行内 → 被替换成占位符，明文不在输出的任何子串里")
    func redactsKnownSecret() {
        let secret = SecretString("sk-abcdef123456")
        let text = "connecting with token=sk-abcdef123456 now"

        let redacted = LogRedactor.redact(text, knownSecrets: [secret])

        #expect(!redacted.contains("sk-abcdef123456"))
        #expect(redacted.contains(SecretString.redactedPlaceholder))
    }

    @Test("值长度 < 4 → 不参与匹配，原样保留")
    func skipsShortValues() {
        let text = "code=abc done"
        let redacted = LogRedactor.redact(text, knownSecrets: [SecretString("abc")])

        #expect(redacted == text)
    }

    @Test("值长度恰为 4 → 参与匹配")
    func matchesValueAtExactThreshold() {
        #expect(LogRedactor.minimumSecretLength == 4)

        let text = "code=abcd done"
        let redacted = LogRedactor.redact(text, knownSecrets: [SecretString("abcd")])

        #expect(!redacted.contains("abcd"))
    }

    @Test("空集 → 原样返回")
    func returnsOriginalWhenNoKnownSecrets() {
        let text = "nothing to hide here"
        #expect(LogRedactor.redact(text, knownSecrets: []) == text)
    }

    @Test("多个已知值 + 一行多次出现 → 全部被遮")
    func redactsEveryOccurrenceOfEveryKnownSecret() {
        let text = "first=secretOne second=secretTwo repeat=secretOne"
        let redacted = LogRedactor.redact(
            text,
            knownSecrets: [SecretString("secretOne"), SecretString("secretTwo")]
        )

        #expect(!redacted.contains("secretOne"))
        #expect(!redacted.contains("secretTwo"))
        #expect(redacted.components(separatedBy: SecretString.redactedPlaceholder).count - 1 == 3)
    }

    @Test("不误遮：与已知值无关的文本原样保留")
    func doesNotTouchUnrelatedText() {
        let text = "the quick brown fox jumps over the lazy dog"
        let redacted = LogRedactor.redact(text, knownSecrets: [SecretString("unrelated-secret-value")])

        #expect(redacted == text)
    }

    /// ★ P1-3：重叠密钥必须按长度降序替换，否则短的先替换会留下长密钥的明文尾巴。
    @Test("重叠密钥：短密钥是长密钥的前缀 → 不留明文尾巴")
    func handlesOverlappingSecretsWithoutLeavingPlaintextTail() {
        let short = SecretString("abcd")
        let long = SecretString("abcdefgh")
        let text = "value=abcdefgh"

        let redacted = LogRedactor.redact(text, knownSecrets: [short, long])

        #expect(!redacted.contains("abcdefgh"))
        #expect(!redacted.contains("efgh"), "长密钥被短密钥先替换，留下了明文尾巴：\(redacted)")
    }

    @Test("重叠密钥：注入顺序是短的在前，结果与顺序无关")
    func overlapHandlingIsOrderIndependent() {
        let short = SecretString("abcd")
        let long = SecretString("abcdefgh")
        let text = "value=abcdefgh"

        let redactedShortFirst = LogRedactor.redact(text, knownSecrets: [short, long])
        let redactedLongFirst = LogRedactor.redact(text, knownSecrets: [long, short])

        #expect(redactedShortFirst == redactedLongFirst)
    }
}
