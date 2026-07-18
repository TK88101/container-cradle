/// 容器状态 → **给人看的一句话**。住 core、可测——和 `SupervisorPresentation` 同一条纪律：
/// 「状态 → 人话」是判断，散在各个 view 里就等于零测试，还会各写各的、慢慢漂
/// （`ContainerRow` 和 `ContainerDetailView` 原本就各抄了一份四分支 switch）。
///
/// 颜色留在 view 里（那是 SwiftUI `Color`，不该下沉到 domain package）；只有文字标签下沉。
public enum ContainerStatePresentation {

    public static func label(for state: ContainerState) -> String {
        switch state {
        case .running: "运行中"
        case .stopped: "已停止"
        case .stopping: "停止中"
        case .unknown: "未知"
        }
    }
}
