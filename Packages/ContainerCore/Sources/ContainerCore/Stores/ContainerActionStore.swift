import Observation

/// 容器生命周期动作（stop / start / restart）的 UI 状态机（DAY13 工作项 1）。
///
/// ## 为什么住 core 而不是 view
///
/// app target 没有测试 target（CLAUDE.md 已踩过的坑）：拒绝制、restart 半失败的区分
/// 都是判断逻辑，放 view 里等于零测试。view 只拿到闭包和状态，保持愚蠢（裁决 #9）。
///
/// ## 并发语义：拒绝制（裁决 #3）
///
/// 同一容器已有进行中动作时，新动作**直接拒绝**（返回 `false`）——不排队、不取消在途。
/// 排队会产生「以为停了它又自己启了」的惊讶；拒绝最不惊讶、最可测。
///
/// 令牌是 `inFlight[id]` 占位：**检查 + 占位是同一段同步代码**，中间没有 `await`——
/// `@MainActor` 在 await 处可重入（★坑清单，本仓库栽过三次），按钮 disabled 只是体验，
/// 这里才是防线。占位的清除走 `defer`，失败路径也必然释放。
@MainActor
@Observable
public final class ContainerActionStore {

    /// 正在进行的动作种类。UI 用它区分 spinner 场景；拒绝制只看「有没有」，不看是哪种。
    public enum Action: Sendable, Equatable {
        case stop
        case start
        case restart
    }

    /// 动作失败的形态。restart 的两段必须分开报（裁决记录 / 计划设计节）：
    /// 「已停止，但启动失败」和「停止就失败了」对用户是完全不同的处境——
    /// 前者容器已经停了，后者容器还在跑。
    public enum ActionFailure: Sendable, Equatable {
        case stopFailed(RuntimeError)
        case startFailed(RuntimeError)
        case restartStopFailed(RuntimeError)
        case restartStartFailed(RuntimeError)
    }

    /// 每容器最近一次失败。**按容器 keyed，和 `inFlight` 同构**——拒绝制既然是按容器
    /// 粒度的，错误态就不能是单槽全局：多个详情窗同时开着时，容器 Y 的成功
    /// 不许冲掉窗口里容器 X 还没被处理的错误横幅。
    /// 该容器新动作成功时只清自己的槽（错误横幅不该永远挂着）。
    private var failures: [ContainerID: ActionFailure] = [:]

    /// 每容器的在途动作。key 存在 = 该容器有动作进行中。
    private var inFlight: [ContainerID: Action] = [:]

    private let client: any ContainerRuntimeClient

    /// 动作结束（无论成败）后触发——注入回调而不是直接依赖 `ContainerListStore`：
    /// 失败路径也刷新，因为 restart 半失败时列表状态已经变了。被拒的动作不触发。
    private let onActionCompleted: @MainActor () async -> Void

    public init(
        client: any ContainerRuntimeClient,
        onActionCompleted: @escaping @MainActor () async -> Void
    ) {
        self.client = client
        self.onActionCompleted = onActionCompleted
    }

    /// 该容器正在进行的动作（`nil` = 空闲）。UI 的 spinner / 禁用态读它。
    public func actionInProgress(for id: ContainerID) -> Action? {
        inFlight[id]
    }

    /// 该容器最近一次失败（`nil` = 无错误）。UI 的错误横幅读它。
    public func error(for id: ContainerID) -> ActionFailure? {
        failures[id]
    }

    /// 停止容器。返回 `false` = 被拒绝制拒掉（同容器已有动作进行中）。
    @discardableResult
    public func stop(id: ContainerID) async -> Bool {
        await run(.stop, on: id) { await self.performStop(id: id) }
    }

    /// 启动容器。返回 `false` = 被拒。
    @discardableResult
    public func start(id: ContainerID) async -> Bool {
        await run(.start, on: id) { await self.performStart(id: id) }
    }

    /// 重启 = stop 成功后 start（上游无原生 restart）。返回 `false` = 被拒。
    ///
    /// 半失败必须可区分：stop 成功、start 失败 → `.restartStartFailed`，
    /// 此时容器**已经停了**——UI 文案要说「已停止，但启动失败」，不能说「重启失败」了事。
    @discardableResult
    public func restart(id: ContainerID) async -> Bool {
        await run(.restart, on: id) { await self.performRestart(id: id) }
    }

    // do/catch 住在普通方法里，不写进闭包：闭包里的类型化 throws 推断不出
    // `RuntimeError`（退化成 `any Error`）——`ContainerListStore.load` 记过的同一条坑。

    private func performStop(id: ContainerID) async -> ActionFailure? {
        do {
            try await client.stop(id: id)
            return nil
        } catch {
            return .stopFailed(error)
        }
    }

    private func performStart(id: ContainerID) async -> ActionFailure? {
        do {
            try await client.start(id: id)
            return nil
        } catch {
            return .startFailed(error)
        }
    }

    private func performRestart(id: ContainerID) async -> ActionFailure? {
        do {
            try await client.stop(id: id)
        } catch {
            return .restartStopFailed(error)
        }

        do {
            try await client.start(id: id)
            return nil
        } catch {
            return .restartStartFailed(error)
        }
    }

    /// 三个动作共用的骨架：同步「检查 + 占位」→ 执行 → 记错 → 释放 → 刷新回调。
    ///
    /// `body` 返回 `nil` = 成功，返回失败形态 = 失败。错误的**分类**由各动作自己做
    /// （restart 的两段语义只有它自己知道），骨架只负责占位纪律和回写。
    private func run(
        _ action: Action,
        on id: ContainerID,
        body: () async -> ActionFailure?
    ) async -> Bool {
        // 检查 + 占位：同步原子段，`await` 之前完成——这是拒绝制的全部防线。
        guard inFlight[id] == nil else { return false }
        inFlight[id] = action

        defer { inFlight[id] = nil }

        let failure = await body()

        // 只动自己的槽：别的容器的错误横幅与本次动作无关。
        failures[id] = failure

        await onActionCompleted()
        return true
    }
}
