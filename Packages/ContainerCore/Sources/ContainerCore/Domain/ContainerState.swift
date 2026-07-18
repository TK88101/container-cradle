/// 容器的运行状态。
///
/// 这四个 case 与上游 `ContainerResource.RuntimeStatus` 一一对应（已核实源码：
/// `unknown` / `stopped` / `running` / `stopping`，无 `created`、无 `paused`）。
///
/// ## 为什么明知一样还要自己再定义一遍
///
/// D1：protocol 签名里只准有 domain 类型。直接用上游的 enum，就等于让 UI、supervisor、
/// reducer 全都 `import ContainerResource`——爆炸半径从 4 个文件炸成整个 app。
///
/// ## 为什么刻意不给 raw value
///
/// 给了 `String` raw value，mapper 就会忍不住写 `ContainerState(rawValue: upstream.rawValue)`。
/// 那是**静默耦合**：上游哪天把 `stopping` 改叫 `terminating`，这行代码照样编译，
/// 只是运行时开始返回 `nil`——变成一个悄悄消失的状态，而不是一个编译错误。
///
/// mapper 必须写**穷尽的 `switch`**。上游改了 case，构建当场炸——这正是我们要的。
public enum ContainerState: Sendable, Hashable, CaseIterable {
    case unknown
    case stopped
    case running
    case stopping
}
