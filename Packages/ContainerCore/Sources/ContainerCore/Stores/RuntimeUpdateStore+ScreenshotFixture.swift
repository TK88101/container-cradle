#if DEBUG
import Foundation

extension RuntimeUpdateStore {

    /// 仅 DEBUG：菜单截图夹具（codex R5 补评 D，D 辩论第 2–3 轮）——直接摆出「新版本装上了、运行时在跑、还欠这些容器」这一屏：
    /// `startDischarged` 的纯容器欠账 + `.containersNotRestarted`，与真流程是**同一组语义**（按钮标题与状态行同源，不是硬塞一条显示字符串）。
    /// 走真流程要先制造一次解除（升级失败 → 用户在终端起运行时 → supervisor 触发），截图时做不到。
    ///
    /// 只写内存（`setState` + `activeIntent`），**不经 `recordIntent`**——它会写 defaults。
    /// 调用方负责给这个 store 一个惰性环境（CLI / 网络 / defaults / reconcile 全都不真碰），见 app 的 `UpdateScreenshotFixture`。
    public func presentContainerDebtFixture(_ ids: [ContainerID], installed: RuntimeVersion, from: RuntimeVersion) {
        // `.containersNotRestarted` 约定非空（空 = 什么都不欠）：不造真流程到不了的「有义务、没有容器」（codex R6 P2）。
        guard !ids.isEmpty else { return }
        activeIntent = UpdateIntent(
            nonce: UUID(), target: installed, from: from, runtimeWasRunning: true, stopIssued: true,
            runningContainerIDs: ids, managedContainerIDs: [], startDischarged: true
        )
        lastKnownInstalled = installed
        setState(.failed(.installedButNotRestarted(installed), pending: .containersNotRestarted(ids)))
    }
}
#endif
