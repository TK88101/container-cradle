import Foundation

/// `RuntimeError` → 面向用户的技术详情文案。**core 内的单点**（Day 16 B 段 codex #9）。
///
/// 原本是 `ContainerActionPresentation.detail` 的 private helper。B 段出现了第三、第四个
/// 消费者（`ContainerCreationPresentation` / `ImagePullPresentation`），这才是 DRY 的正确
/// 触发点——把 helper 继续挂在 action 上，会让「创建失败」「拉取失败」的文案反向依赖
/// 「动作」这个跟它们不相干的概念。
///
/// **`RuntimeDownBanner`（app target）的第二份刻意不合并**：那是语境分叉——持久横幅会补一句
/// 「挂上后自动重试」，这里的瞬时错误行不补。两处各自进各自的目录翻译。
/// 别照着旧注释以为存在「唯一来源」。
enum RuntimeErrorPresentation {

    /// 穷尽 switch，无 `default`——新增 `RuntimeError` case 时这里编译报错，
    /// 逼着决定新失败形态给用户看什么，而不是被 `default` 吞掉。
    ///
    /// `.operationFailed` 的 reason 是 runtime 层的英文诊断串，**原样透传不翻译**
    /// （Day 14 计划 §1：技术详情保持可搜索；UI 层负责用「Technical detail」框架标注）。
    static func detail(_ error: RuntimeError, locale: Locale = .current) -> String {
        switch error {
        case .runtimeUnavailable:
            String(coreLocalized: "The container runtime is not running", locale: locale)
        case .containerNotFound(let id):
            String(
                coreLocalized: "Container \(id.rawValue) not found. It may have been deleted.",
                locale: locale
            )
        case .mountSourceUnavailable(let path):
            String(
                coreLocalized:
                    "\(path) does not exist on the host yet. An external disk or network volume may not be attached.",
                locale: locale
            )
        case .operationFailed(let reason):
            reason
        }
    }
}
