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
        case .outcomeUnknown:
            // 不透传 reason：「XPC call timed out」读起来就是失败，而这里要说的恰恰是「可能还没失败」。
            outcomeUnknownText(locale: locale)
        case .creationInProgress(let name):
            String(
                coreLocalized:
                    "A container named \(name) is already being created in this app. The name stays reserved until that request returns or you reopen the app. Check the container list in the menu before trying again.",
                locale: locale
            )
        case .creationLimitReached(let limit):
            String(
                coreLocalized:
                    "\(limit) container creations are still in progress. Wait for them to finish, then try again. If this persists, reopen the app.",
                locale: locale
            )
        }
    }

    /// create / clone 提交**不算失败**时的完整文案（结果未定 / 本 App 挡下没发出，Day 24–25）；其余返回 nil，
    /// 由调用方加 "Create failed:" / "Clone failed:" 前缀。穷尽 switch：新 case 必须在这里表态它算不算「失败」。
    static func notFailedCreationText(_ error: RuntimeError, locale: Locale) -> String? {
        switch error {
        case .outcomeUnknown, .creationInProgress, .creationLimitReached:
            detail(error, locale: locale)
        case .runtimeUnavailable, .containerNotFound, .mountSourceUnavailable, .operationFailed:
            nil
        }
    }

    /// `.outcomeUnknown` 的用户文案（create / clone 提交失败也直接用它，不加 "Create failed:" 前缀）。
    static func outcomeUnknownText(locale: Locale) -> String {
        String(
            coreLocalized:
                "This is taking longer than expected and may still finish. Check the container list in the menu before trying again.",
            locale: locale
        )
    }
}
