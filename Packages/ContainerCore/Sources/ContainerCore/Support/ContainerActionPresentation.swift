import Foundation

/// 容器动作失败的用户文案（Day 13 工作项 1）。住 core 的理由同
/// `ContainerStatePresentation`：app target 零测试，文案分支放 view 里就没人守
/// 「restart 半失败必须报『已停止，但启动失败』」这条要求了。
public enum ContainerActionPresentation {

    /// 完整的一行错误文案：失败形态 + 底层原因。
    public static func message(
        for failure: ContainerActionStore.ActionFailure,
        locale: Locale = .current
    ) -> String {
        switch failure {
        case .stopFailed(let error):
            String(coreLocalized: "Stop failed: \(detail(error, locale: locale))", locale: locale)
        case .startFailed(let error):
            String(coreLocalized: "Start failed: \(detail(error, locale: locale))", locale: locale)
        case .restartStopFailed(let error):
            String(
                coreLocalized:
                    "Restart failed (stop phase failed; the container is still running): \(detail(error, locale: locale))",
                locale: locale
            )
        case .restartStartFailed(let error):
            String(
                coreLocalized: "Stopped, but start failed: \(detail(error, locale: locale))",
                locale: locale
            )
        }
    }

    /// `RuntimeError` → 动作错误行的展示文案。
    /// **不是单一来源**：`RuntimeDownBanner`（app target）另有一份自己的 `RuntimeError`
    /// switch，按横幅语境措辞（持久横幅 vs 这里的瞬时动作行），且刻意分叉——
    /// 例如它的 `.mountSourceUnavailable` 会补一句「挂上后自动重试」，这里不补。
    /// 两处各自进各自的目录翻译；本地化没有把它们合并（原计划想合，评估后维持分开：
    /// 语境不同，措辞本就该不同）。别照着旧注释以为这里是唯一来源。
    /// 穷尽 switch——新增 case 时这里编译报错，
    /// 逼着决定新失败形态给用户看什么，而不是被 default 吞掉。
    ///
    /// `.operationFailed` 的 reason 是 runtime 层的英文诊断串，**原样透传不翻译**
    /// （Day 14 计划 §1：技术详情保持可搜索；UI 层负责用「Technical detail」框架标注）。
    private static func detail(_ error: RuntimeError, locale: Locale) -> String {
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
