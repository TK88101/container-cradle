import Foundation

/// 容器标识符。**非法值构造不出来。**
///
/// ID 有三个外部来源，一个都不可信：上游 snapshot 的 `id`、用户手写的白名单配置、UI 输入。
/// 与其在每个用到 ID 的地方判空，不如让「空 ID」这个值根本不存在。
///
/// ## 校验刻意只挡空白，不挡别的
///
/// 诱惑是加一条字符白名单（`[a-zA-Z0-9._-]`）。**不能加**：
/// 校验一旦比上游严，mapper 就会拒掉一个上游认为合法的容器，
/// 而那个容器会**从列表里静默消失**——用户看不到它，supervisor 也不会去拉它。
/// 那是比「ID 长得怪」严重得多的故障，且完全无声。
///
/// 校验规则的方向必须是：**不严于上游**。上游允许的，这里一律放行。
public struct ContainerID: Hashable, Sendable, CustomStringConvertible, Codable {

    public let rawValue: String

    /// 首尾空白会被裁掉——上游的 ID 本来就不带空白（裁了是 no-op），
    /// 而用户手写配置很容易多敲一个空格，这里替他吸收掉。
    /// 裁完为空 → `nil`。
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

// MARK: - Codable

/// **合成实现在这里是不能用的**，理由和 `SecretString` 刻意不遵从 `Decodable` 同源。
///
/// 合成的 `Decodable` 直接往 `rawValue` 里塞字符串，**完全绕过 `init?` 的校验**——
/// 白名单 JSON 里写一个 `""`，就能解出一个「空 ID」的 `ContainerID`。
/// 于是那条「非法值构造不出来」的不变式当场作废，而且是从**最不可信的入口**
/// （用户手写的配置文件）被绕开的。
///
/// 编码形式也刻意是**裸字符串**（`"open-connector"`）而不是 `{"rawValue": "..."}`：
/// 白名单是**给人看、给人改**的配置资产（PLAN：它要能查看、手改、备份、进 git），
/// 多一层包装只是让人更难改对。
extension ContainerID {

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)

        guard let id = ContainerID(raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "容器 ID 不能为空"
            ))
        }

        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
