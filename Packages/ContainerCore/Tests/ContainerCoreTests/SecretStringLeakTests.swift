import Foundation
import Testing

@testable import ContainerCore

/// D2 硬约束的可执行证明（CLAUDE.md / PLAN.md）。
///
/// 实测事实（Spikes/SPIKE-RESULT.md）：本机 open-connector 容器的 env 里有 3 个 44 字符明文密钥。
/// 这些测试的作用是让「不小心把密钥 log 出去」成为**写不出来的代码**——
/// 每一条都对应一个真实的泄漏渠道，全部必须产出 <redacted>。
@Suite("SecretString 泄漏防护")
struct SecretStringLeakTests {

    /// 合成值，非真实密钥。形状仿真：44 字符 + base64 的 '=' 尾巴。
    static let plaintext = "sk-Ab3dEf6hIj9lMn2pQr5tUv8xYz1cDe4fGh7jKl0mNo="

    // MARK: - 泄漏渠道

    @Test("字符串插值不泄漏")
    func interpolationIsRedacted() {
        let secret = SecretString(Self.plaintext)
        #expect("\(secret)" == "<redacted>")
    }

    @Test("String(describing:) 不泄漏")
    func describingIsRedacted() {
        let secret = SecretString(Self.plaintext)
        #expect(String(describing: secret) == "<redacted>")
    }

    @Test("debugDescription 不泄漏")
    func debugDescriptionIsRedacted() {
        let secret = SecretString(Self.plaintext)
        #expect(String(reflecting: secret) == "<redacted>")
    }

    /// dump() 走 Mirror 反射，会绕过 description 直接打印存储属性——
    /// 这是最容易被忽略的泄漏渠道，必须用 CustomReflectable 堵死。
    @Test("dump() 反射不泄漏")
    func dumpIsRedacted() {
        let secret = SecretString(Self.plaintext)
        var output = ""
        dump(secret, to: &output)
        #expect(!output.contains(Self.plaintext))
    }

    @Test("JSON 编码不泄漏")
    func jsonEncodingIsRedacted() throws {
        let secret = SecretString(Self.plaintext)
        let data = try JSONEncoder().encode(secret)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains(Self.plaintext))
        #expect(json.contains("<redacted>"))
    }

    /// 嵌套在容器类型里编码时同样不能泄漏——真实泄漏往往是 encode 整个 Container。
    @Test("嵌套在结构体里编码不泄漏")
    func nestedEncodingIsRedacted() throws {
        struct Wrapper: Encodable {
            let name: String
            let value: SecretString
        }
        let wrapper = Wrapper(name: "OOMOL_CONNECT_ENCRYPTION_KEY", value: SecretString(Self.plaintext))

        let data = try JSONEncoder().encode(wrapper)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains(Self.plaintext))
        #expect(json.contains("OOMOL_CONNECT_ENCRYPTION_KEY"))
    }

    // MARK: - 明文出口

    @Test("reveal() 是取明文的唯一出口")
    func revealReturnsPlaintext() {
        let secret = SecretString(Self.plaintext)
        #expect(secret.reveal() == Self.plaintext)
    }

    // MARK: - 刻意缺席的 conformance

    /// 实现 `Decodable` 会让 `<redacted>` 被解回来当成明文——一个内容是字面量
    /// "<redacted>" 的假密钥，静默地流进下游。这个决定是载荷性的，不能只活在注释里。
    @Test("刻意不遵从 Decodable")
    func doesNotConformToDecodable() {
        #expect(SecretString.self as? any Decodable.Type == nil)
    }

    /// 合成的 `Hashable` 会把 `hashValue`（`Int`，os.Logger 对数值默认 .public）
    /// 变成明文的稳定指纹——绕开全部脱敏，且不需要调 reveal()，grep 审计也抓不到。
    /// 见 SecretString 的类型注释。
    @Test("刻意不遵从 Hashable")
    func doesNotConformToHashable() {
        #expect(SecretString.self as? any Hashable.Type == nil)
    }

    // MARK: - 值语义

    @Test("相同明文的 SecretString 相等")
    func equalityComparesPlaintext() {
        #expect(SecretString(Self.plaintext) == SecretString(Self.plaintext))
        #expect(SecretString("a") != SecretString("b"))
    }

    @Test("isEmpty 反映明文而不泄漏明文")
    func isEmptyReflectsPlaintext() {
        #expect(SecretString("").isEmpty)
        #expect(!SecretString(Self.plaintext).isEmpty)
        #expect("\(SecretString(""))" == "<redacted>")
    }
}
