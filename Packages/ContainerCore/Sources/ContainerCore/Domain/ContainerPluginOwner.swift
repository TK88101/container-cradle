/// 上游 `com.apple.container.plugin` 标签的值：**「这个容器归某个插件管」**（Day 29）。
///
/// machine / cluster 节点、buildkit（值 `builder`）都由各自插件管理生命周期。上游 1.7.1 只在
/// **CLI** 层拦（`ContainerCommands`），XPC 的 `ContainerClient` 不拦——我们直调 XPC，所以得自己拦：
/// supervisor 不拉、菜单不启停、不可勾进白名单。
///
/// ## 判定只看「有没有」，不看值
///
/// 标签键存在（值为空串也算）⇒ 插件管理。fail-safe：宁可不让勾，也不和插件抢。
/// `rawValue` 原样保留只为展示——它是上游快照里的**任意字串**，不可信（日志一律 `.private`，
/// 展示走 `ContainerPluginOwnerPresentation.displayName` 单行化 + 截断）。
public struct ContainerPluginOwner: Sendable, Equatable, Hashable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 镜像上游 `ResourcePluginValues.machine`（runtime 侧有对照测试）。
    public static let machine = ContainerPluginOwner(rawValue: "machine")

    /// 镜像上游 `ResourcePluginValues.cluster`（runtime 侧有对照测试）。
    public static let cluster = ContainerPluginOwner(rawValue: "cluster")

    /// 与 CLI `container ls` 同语义：只有**精确等于**这两个上游常量的才不出现在列表里。
    /// 其它值（builder、未来插件、空串）照常显示、标注、不可纳管——隐藏未知值会让容器「凭空消失」。
    public var isHiddenFromContainerList: Bool {
        self == .machine || self == .cluster
    }
}
