import Foundation

/// 菜单容器列表的展示规则（Day 29）。**过滤只在展示层**：`ContainerListStore` 保留全量——
/// 在 store / `list()` 层滤掉 plugin 容器，它们的白名单条目就会被 `WhitelistOrphanPolicy` 误判成孤儿、
/// 摆出删除按钮（Plan F10）。
public enum ContainerListPresentation {

    /// 菜单里显示哪些容器：与 CLI `container ls` 同语义，只隐藏精确的 machine / cluster。
    public static func visibleInMenu(_ containers: [Container]) -> [Container] {
        containers.filter { !($0.pluginOwner?.isHiddenFromContainerList ?? false) }
    }
}

/// owner 的展示。`rawValue` 是上游快照里的任意字串：可能为空、超长、带换行。
public enum ContainerPluginOwnerPresentation {

    static let maxDisplayLength = 32

    /// 单行化（空白 / 控制字符折成一个空格）+ trim + 截断；没有可显示的内容 ⇒ `nil`（调用方用 generic 文案）。
    public static func displayName(_ owner: ContainerPluginOwner) -> String? {
        let words = owner.rawValue.unicodeScalars
            .split { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        guard !words.isEmpty else { return nil }
        let single = words.joined(separator: " ")
        guard single.count > maxDisplayLength else { return single }
        return String(single.prefix(maxDisplayLength - 1)) + "…"
    }

    /// 列表行内的一句说明。
    public static func managedByText(_ owner: ContainerPluginOwner, locale: Locale = .current) -> String {
        guard let name = displayName(owner) else {
            return String(coreLocalized: "Managed by a plugin", locale: locale)
        }
        return String(coreLocalized: "Managed by plugin “\(name)”", locale: locale)
    }
}
