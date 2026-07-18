import Foundation

/// 破坏性操作的「打出名字才放行」判据。**住 core 所以可测**——判断不留在 view 里
/// （app target 没有测试 target，而「删除门槛松了」正是没人会在肉眼 review 里发现的那种 bug）。
///
/// 语义**刻意收紧**（codex P2-2）：删 volume 的确认要和 CLI 的 `down.sh --purge` 一样严，
/// GUI 不能比脚本更松。
public enum TypedConfirmation {

    /// 输入是否足以放行删除。
    ///
    /// - **精确匹配**：`typed == expected`，一个字都不能差。
    /// - **大小写敏感**：`Data` 与 `data` 是两个 volume，绝不能混。
    /// - **不 trim 普通空格**：名字首尾若真带空格（合法），trim 掉会让两个不同的 volume 撞名。
    /// - **只去掉首尾换行**：那是输入框 / 粘贴可能带进来的、用户看不见的字符，
    ///   不该成为「明明打对了却点不了删除」的障碍。
    public static func canConfirm(typed: String, expected: String) -> Bool {
        // 空期望值不给放行：没有靶子的确认框不该存在，更不该「空==空」就通过。
        guard !expected.isEmpty else { return false }

        return typed.trimmingCharacters(in: .newlines) == expected
    }
}
