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
        case .deleteFailed(let error):
            // Day 16 T9.4：英文文案落地；四语译文 = B 段 T9.10 债务（本轮不跑 check-localization）。
            String(coreLocalized: "Delete failed: \(detail(error, locale: locale))", locale: locale)
        }
    }

    /// `RuntimeError` → 动作错误行的展示文案。
    ///
    /// Day 16 B 段起，实现搬到了 `RuntimeErrorPresentation`（core 内单点，三处共用）——
    /// 这里只剩转调。**依然不是「唯一来源」**：`RuntimeDownBanner`（app target）另有一份
    /// 自己的 `RuntimeError` switch，按横幅语境措辞且刻意分叉（它的 `.mountSourceUnavailable`
    /// 会补一句「挂上后自动重试」，这里不补）。别照着旧注释以为全仓只有一处。
    private static func detail(_ error: RuntimeError, locale: Locale) -> String {
        RuntimeErrorPresentation.detail(error, locale: locale)
    }
}
