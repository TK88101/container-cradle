import Foundation

/// pull 的失败文案与状态标签。**进度数值不在这里**——那是 `PullProgress.display`
/// （三档降级已测），这里只回答「这一行状态用什么话说」。
///
/// 住 core 的理由：app target 没有测试 target，文案 switch 放 view 里等于零测试。
public enum ImagePullPresentation {

    /// 穷尽 switch，无 `default`——`FailureKind` 新增 case 时这里编译报错。
    ///
    /// 两个通道刻意分开措辞：`setup` 是**还没开始下载**（建流就失败），
    /// `stream` 是**下到一半断了**。对用户是不同处境（前者多半是镜像名/运行时问题，
    /// 后者多半是网络），说成同一句话会让人查错方向。
    public static func message(
        for kind: ImagePullStore.FailureKind,
        locale: Locale = .current
    ) -> String {
        switch kind {
        case .setup(let error):
            String(
                coreLocalized:
                    "Could not start the pull: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                locale: locale
            )
        case .stream(let description):
            // 流内错误是 `localizedDescription` 字符串——**原样透传**，同技术详情纪律。
            String(coreLocalized: "The pull was interrupted: \(description)", locale: locale)
        }
    }

    /// 穷尽 switch，无 `default`——`State` 新增 case 时这里编译报错。
    public static func statusLabel(
        for state: ImagePullStore.State,
        locale: Locale = .current
    ) -> String {
        switch state {
        case .idle:
            String(coreLocalized: "Enter an image reference to pull", locale: locale)
        case .pulling(let reference, _):
            String(coreLocalized: "Pulling \(reference.rawValue)…", locale: locale)
        case .cancellingForeground(let reference):
            // ★ **不得说成「已取消 / 已停止」**：A 段刻意规定 `cancel()` 是**前台放弃**，
            // 不调 `onCompleted`、也管不到运行时那边——后台可能仍在下载。
            // 说「已停止」就是 UI 在承诺一件 core 明确没做的事。
            String(
                coreLocalized: "Stopped waiting for \(reference.rawValue); it may still be downloading",
                locale: locale
            )
        case .failed(let reference, let kind):
            String(
                coreLocalized: "\(reference.rawValue) failed: \(message(for: kind, locale: locale))",
                locale: locale
            )
        case .done(let reference):
            String(coreLocalized: "Pulled \(reference.rawValue)", locale: locale)
        }
    }
}
