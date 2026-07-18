import Observation

/// 容器列表的 UI 状态。**没有事件流，只能轮询**（`XPCRoute.containerEvent` 是死枚举，
/// 路由表里从未接线——CLAUDE.md 已核实），所以刷新是显式动作，不是订阅。
///
/// M0 只在菜单打开时拉一次。真正的 `PollLoop`（单飞 + poke + 退避 + 取消）是 M2 的活，
/// 现在塞进来只会得到一个没有 supervisor 可服务的定时器。
///
/// ## 它为什么住在 `ContainerCore` 而不是 app target
///
/// PLAN 原本把 Stores 放在 app target。但它**不 import SwiftUI**——它是一台纯状态机，
/// 输入是 `ContainerRuntimeClient`，输出是 `LoadState`。而 app target 没有测试 target，
/// 放在那儿它就一行测试都跑不了；下面那条乱序 bug 正是这么漏出去的（review 才抓到）。
///
/// 搬进 library 后 `swift test` 直接覆盖它，且不破坏 D1：它只碰 domain 类型。
@MainActor
@Observable
public final class ContainerListStore {

    /// 三态 enum，而不是「数组 + error + isLoading 布尔」三个独立字段。
    ///
    /// 三个字段能表达 `isLoading && error != nil && !containers.isEmpty` 这种**无意义组合**，
    /// 然后 view 里就得写一堆分支去猜谁优先。enum 让非法状态无法表示。
    public enum LoadState {
        case loading
        case loaded([Container])

        /// 失败**带着上一次的快照**——这是这个 App 最重要的一个 UI 决定。
        ///
        /// 运行时挂掉的那一瞬，用户屏幕上正显示着容器列表。把它清成空白，
        /// 用户的第一反应是「我的容器被删了？」——而真相是「运行时不在了，
        /// 这是它倒下前的样子」。后者才是该显示的东西。
        ///
        /// 所以失败态的职责是**解释为什么停止更新**，不是抹掉已知事实。
        /// 首次加载就失败时 `lastKnown` 为空，那时才该显示纯粹的降级 UI。
        case failed(RuntimeError, lastKnown: [Container])
    }

    public private(set) var state: LoadState = .loading

    /// 当前该显示的容器：`.loaded` 的那份，或运行时挂掉后保留的上一份快照，`.loading` 时为空。
    /// **详情窗口按 id 查它**——查找逻辑住 core（可测），不留在未测的 app 层。
    public var displayedContainers: [Container] {
        switch state {
        case .loading:
            []
        case .loaded(let containers):
            containers
        case .failed(_, let lastKnown):
            lastKnown
        }
    }

    private let client: any ContainerRuntimeClient

    /// 在途的那次刷新。**单飞**：新刷新一来，旧的就作废。
    private var inFlight: Task<Void, Never>?

    public init(client: any ContainerRuntimeClient) {
        self.client = client
    }

    /// 刷新。**后发起的胜出**——先发起的那次即使后返回，也不会写回 `state`。
    ///
    /// 这不是洁癖。`.task` 的首次刷新还挂在 `await client.list()` 上时用户点了刷新按钮，
    /// 于是两个请求在途——而它们的**返回顺序不由发起顺序决定**（M1 接上 XPC 后尤其如此）。
    /// 旧请求后返回并覆盖 `state`，用户看到的就是一份已被取代的列表，
    /// 而且没有任何东西会纠正它，直到下一次刷新。
    ///
    /// `@MainActor` 挡不住这个：MainActor 在 `await` 处是**可重入**的。
    /// 挡住它的是下面这个 `Task` 令牌——旧任务被 cancel，恢复后自己闭嘴。
    ///
    /// cancel 在这里的作用是**作废**，不是**中止**：`ContainerRuntimeClient` 没有取消语义，
    /// 旧请求照跑到底，只是结果不许落地。
    public func refresh() async {
        inFlight?.cancel()

        let task = Task { await self.load() }

        inFlight = task
        await task.value
    }

    /// do/catch 刻意留在普通方法里，不写进 `Task` 的闭包：
    /// 闭包里的类型化 throws 推断不出 `RuntimeError`（退化成 `any Error`），
    /// `.failed` 就接不住了。
    private func load() async {
        do {
            let containers = try await client.list()
            guard !Task.isCancelled else { return }
            state = .loaded(containers)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error, lastKnown: lastKnownContainers)
        }
    }

    /// 失败时要保留的东西：已加载的列表，或上一次失败时就已经在保留的那份。
    /// （连续失败不该让快照在第二次失败时凭空消失。）
    private var lastKnownContainers: [Container] {
        switch state {
        case .loading:
            []
        case .loaded(let containers):
            containers
        case .failed(_, let lastKnown):
            lastKnown
        }
    }
}
