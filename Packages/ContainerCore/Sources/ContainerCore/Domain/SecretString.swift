/// 一个明文值，其**默认行为是不显示自己**。
///
/// D2（CLAUDE.md）：密钥脱敏是类型级的，不是 UI 规则。
/// `container ls --format json` 返回的 `configuration.initProcess.environment` 里是明文密钥——
/// 实测本机 open-connector 容器 env 内有 3 个 44 字符明文密钥（Spikes/SPIKE-RESULT.md）。
///
/// 老实渲染 env = 密钥出现在屏幕、每张截图、每次录屏、每份崩溃报告里。
/// 所以这里堵死全部被动泄漏渠道——插值、`description`、`debugDescription`、
/// 反射（`dump`）、`Encodable`——要拿明文**必须显式调 `reveal()`**。
///
/// 于是「不小心把密钥 log 出去」不是靠 code review 拦，而是**写不出来的代码**。
///
/// ## 刻意不遵从 `Hashable`
///
/// 合成的 `Hashable` 会直接对 `plaintext` 求 hash，而 `hashValue` 是 `Int`——
/// `os.Logger` 对数值类型**默认 `.public`**（只有 `String`/泛型才默认 `.private`）。
/// 于是 `logger.log("\(secret.hashValue)")` 能编译、能跑，且明文的稳定指纹直接进日志：
/// 这条路径绕开下面所有 conformance，还不需要调 `reveal()`，连 grep 审计都抓不到。
///
/// 目前没有任何 `Set`/`Dictionary` 需要它。要用时须显式设计（对 key 而非 value 求 hash），
/// 不能靠合成。
///
/// ## `Equatable` 的已知边界
///
/// `==` 由编译器合成为 `String.==`，**非常量时间**。本 App 只用它比较容器配置的差异
/// （只读展示），不拿它做凭据校验，故不构成时序侧信道。若将来用于认证路径，须改写。
public struct SecretString: Sendable, Equatable {

    /// 一切脱敏渠道的统一产出。
    public static let redactedPlaceholder = "<redacted>"

    private let plaintext: String

    public init(_ plaintext: String) {
        self.plaintext = plaintext
    }

    /// 取明文的**唯一**出口。调用点即审计点：`D1BoundaryTests` 要求 `Sources/` 下的每一个调用点
    /// 都登记进白名单（M0 是空集），未登记即红灯。
    ///
    /// 本文件里刻意不写出那个调用形态的字面样子——连注释里都不写。边界扫描器是纯文本的，
    /// 且**刻意不去理解注释**：剥注释会带来假阴性，而 R2 的失败不可挽回，保守误报好过静默漏报。
    public func reveal() -> String {
        plaintext
    }

    public var isEmpty: Bool {
        plaintext.isEmpty
    }
}

// MARK: - 泄漏渠道封堵

extension SecretString: CustomStringConvertible {
    /// 覆盖字符串插值 `"\(secret)"` 与 `String(describing:)`。
    public var description: String { Self.redactedPlaceholder }
}

extension SecretString: CustomDebugStringConvertible {
    /// 覆盖 `String(reflecting:)`、`po` 与 os.Logger 的 debug 渲染。
    public var debugDescription: String { Self.redactedPlaceholder }
}

extension SecretString: CustomReflectable {
    /// `dump()` 与 Mirror 会绕过 `description` 直接读存储属性——这是最隐蔽的泄漏渠道。
    /// 对外只暴露占位符，`plaintext` 存储属性在反射中完全不可见。
    public var customMirror: Mirror {
        Mirror(self, children: ["value": Self.redactedPlaceholder])
    }
}

extension SecretString: Encodable {
    /// 编码恒定产出 `<redacted>`：误 `encode` 整个 `Container` 时也不会把密钥写进 JSON。
    ///
    /// **刻意不实现 `Decodable`**——否则从 `<redacted>` 解回来会得到一个内容为字面量
    /// "<redacted>" 的假密钥，静默地把占位符当明文用。上游 JSON 走 mapper 显式构造，
    /// 不经由 `Decodable`。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.redactedPlaceholder)
    }
}
