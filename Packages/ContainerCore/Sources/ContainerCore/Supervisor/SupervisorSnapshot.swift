/// supervisor 每处理完**一个事件**，往外投的一份快照。UI 靠它活着。
///
/// ## 为什么是「一个通道」而不是「状态一个 + 通知一个」
///
/// 两个通道意味着同一次 `handle` 的产物被拆成两半，各自跨一次 actor → MainActor 的跳转——
/// 而**跳转不保证顺序**。于是能出现「新状态已经到了，旧通知随后盖上来」：
/// 界面显示 `.runtimeUp`，底下挂着一行「熔断了」。两个字段各自都对，凑在一起是假的。
///
/// 一次 `handle` = 一份快照 = 一次投递。UI 拿到的永远是**一个自洽的横截面**。
///
/// ## `sequence` 不是装饰
///
/// 从 actor 投到 `@MainActor` 必然经过 `Task { @MainActor in ... }`，而两个 Task 的执行顺序
/// **不由创建顺序决定**。没有 sequence，一份迟到的旧快照就能把界面拽回过去
/// （见 `SupervisorStatusStore.apply`）。
///
/// 这是本仓库第四次遇到同一个形状：**跨过 await 之后，得重新证明自己是最新的那一个。**
public struct SupervisorSnapshot: Sendable, Equatable {

    public let state: SupervisorState

    /// 这一次 `handle` 里 reducer 要求发出的通知。通常 0 条，偶尔 1 条。
    public let notices: [SupervisorNotice]

    /// 单调递增。**永远由同一个 actor 递增**，所以它是全序的。
    public let sequence: Int

    public init(state: SupervisorState, notices: [SupervisorNotice], sequence: Int) {
        self.state = state
        self.notices = notices
        self.sequence = sequence
    }
}
