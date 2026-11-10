/// 「哪些容器归插件管」「扣掉它们之后还剩哪些受管」——给白名单的非 supervisor 消费者用（Plan G5）。
public enum ManagedContainerSet {

    public static func pluginIDs(in known: [Container]) -> Set<ContainerID> {
        Set(known.filter(\.isPluginManaged).map(\.id))
    }

    /// enabled − 已知 plugin。`known` 为空（列表从未加载）⇒ 不减：「未知」按保守方向处理——
    /// 多拉一次运行时无害，漏拉真受管容器才违背 supervisor 的核心价值（Plan §6 R4）。
    public static func effective(enabled: Set<ContainerID>, known: [Container]) -> Set<ContainerID> {
        enabled.subtracting(pluginIDs(in: known))
    }
}
