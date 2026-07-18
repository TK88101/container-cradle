/// 白名单里的一条：**「运行时回来时，请把这个容器拉起来」**。
///
/// ## 为什么只有两个字段
///
/// PLAN 的 supervisor 一节提过 `keepAlive`（容器自己崩了要不要拉）和 `startDelay`。
/// 这里**都不加**——理由和 `Container` 不带 `startedAt` 是同一条：**它们现在没有消费者。**
///
/// `ReconcileEngine` 只做一件事：运行时换代时把 enabled 的条目拉起来。它不看 keepAlive
/// （那需要持续轮询容器状态，是另一套机制），也不看 startDelay（v1 明确不做依赖图）。
/// 带上一个没人读的字段，等于让它躲开一切测试压力，然后在真要用它的那天已经漂了。
///
/// Codable 加字段是向后兼容的（老 JSON 解码时给默认值），所以「以后再加」不欠债。
public struct WhitelistEntry: Sendable, Equatable, Codable {

    public let id: ContainerID

    /// 受管开关。**false 不等于「从白名单删掉」**——
    /// 用户临时停掉一个容器去调试时，要能关掉它的自动拉起而**不丢掉这条配置**
    /// （否则调试完还得重新加一遍，然后大概率忘了加）。
    public let enabled: Bool

    public init(id: ContainerID, enabled: Bool = true) {
        self.id = id
        self.enabled = enabled
    }
}

/// 「现在该管哪些容器？」
///
/// 抽成 protocol 是为了让 `ReconcileEngine` 的测试不用碰文件系统。
/// 生产实现是 `WhitelistStore`（原子写 JSON + 损坏降级）。
public protocol WhitelistProvider: Sendable {

    func entries() async -> [WhitelistEntry]
}
