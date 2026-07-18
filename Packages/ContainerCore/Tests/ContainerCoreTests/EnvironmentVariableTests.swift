import Foundation
import Testing

@testable import ContainerCore

/// 上游 `ProcessConfiguration.environment` 是 `[String]`（形如 "KEY=VALUE"），不是字典
/// ——这是 spike 的实测发现（Spikes/SPIKE-RESULT.md）。解析规则由此而来。
@Suite("EnvironmentVariable 解析")
struct EnvironmentVariableTests {

    /// 合成值，非真实密钥。刻意带 base64 的 '=' 尾巴，用来钉死「按首个 = 切分」。
    static let secretValue = "sk-Ab3dEf6hIj9lMn2pQr5tUv8xYz1cDe4fGh7jKl0mNo="

    @Test("按首个 = 切分出 key 与 value")
    func parsesSimplePair() throws {
        let variable = try #require(EnvironmentVariable(parsing: "NODE_ENV=production"))

        #expect(variable.key == "NODE_ENV")
        #expect(variable.value.reveal() == "production")
    }

    /// 值里含 '='（base64 密钥就是这样）时，只能切第一个 '='——
    /// 切错会得到一个被截断的密钥，且错误无声。
    @Test("值内含 = 时只切首个")
    func splitsOnFirstEqualsOnly() throws {
        let raw = "OOMOL_CONNECT_ENCRYPTION_KEY=\(Self.secretValue)"
        let variable = try #require(EnvironmentVariable(parsing: raw))

        #expect(variable.key == "OOMOL_CONNECT_ENCRYPTION_KEY")
        #expect(variable.value.reveal() == Self.secretValue)
    }

    @Test("空值合法")
    func parsesEmptyValue() throws {
        let variable = try #require(EnvironmentVariable(parsing: "EMPTY="))

        #expect(variable.key == "EMPTY")
        #expect(variable.value.isEmpty)
    }

    /// 畸形条目降级为 nil，绝不崩——上游没有 schema 承诺，mapper 必须能吞下意外输入（R1）。
    /// 前三例无 '='；"=orphan" 有 '=' 但 key 为空——注意 `split` 会把 "orphan" 悄悄提升成
    /// key，这正是不用 split 的原因之一。
    @Test("畸形条目降级为 nil，不崩", arguments: ["MALFORMED", "", "   ", "=orphan"])
    func rejectsMalformedEntry(raw: String) {
        #expect(EnvironmentVariable(parsing: raw) == nil)
    }

    @Test("值默认脱敏，不因解析而暴露")
    func valueStaysRedactedAfterParsing() throws {
        let variable = try #require(
            EnvironmentVariable(parsing: "OOMOL_CONNECT_ADMIN_TOKEN=\(Self.secretValue)")
        )

        #expect("\(variable.value)" == "<redacted>")

        let json = String(decoding: try JSONEncoder().encode(variable), as: UTF8.self)
        #expect(!json.contains(Self.secretValue))
        #expect(json.contains("OOMOL_CONNECT_ADMIN_TOKEN"))
    }
}
