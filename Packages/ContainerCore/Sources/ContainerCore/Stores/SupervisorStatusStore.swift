import Observation

/// supervisor 状态在 UI 侧的镜像。**菜单栏图标和状态行读的就是它。**
///
/// 它住在 `ContainerCore` 而不是 app target，理由和 `ContainerListStore` 一模一样：
/// app target 没有测试 target，放那儿它一行测试都跑不了——而它要守的恰恰是一条
/// **并发不变式**（乱序快照不许落地），那是最不该靠肉眼 review 去守的东西。
@MainActor
@Observable
public final class SupervisorStatusStore {

    public private(set) var state: SupervisorState = .unknown

    /// 最近一条通知。**它只在自己所属的那个状态里有效。**
    ///
    /// 两个方向都会出错，所以规则不能简单化：
    ///
    /// - **一律清掉**（每轮快照都重置）→ `.cooldown` 里轮询一直在跑，每一轮都是
    ///   「状态照旧、没有通知」，于是漫长的退避里用户只看得到「等待重试」，
    ///   看不到「因为外置盘还没挂上」——而后者才是他该去插硬盘的那条信息。
    ///
    /// - **一直留着**（我的第一版，codex review 抓到）→ 熔断后用户按「立即启动受管容器」，
    ///   状态变成 `.reconciling` 且不带通知，界面于是同时写着「正在拉起受管容器…」和
    ///   「已停止自动重试」。两行互相打脸，而且下面那行**是假的**。
    ///
    /// 规则：状态没变 → 通知还成立，留着；状态变了又没带新通知 → 它已经过期，清掉。
    public private(set) var lastNotice: SupervisorNotice?

    /// 已经采纳过的最大 sequence。
    private var appliedSequence = 0

    /// **本次快照里新出现的通知**（Day 8：系统通知桥接挂这里）。
    ///
    /// codex P1-7：通知桥接必须消费**这条事件流**，不能从留存态 `lastNotice` 反推——
    /// 后者会在状态不变时保留旧通知（是 UI 设计），任何 view/store 重建都可能把它再当成新事件重弹。
    /// 这里投出去的是「这一份被采纳的快照带来的」notices，只在 sequence 闸通过后触发一次。
    @ObservationIgnored public var onNotices: (@MainActor ([SupervisorNotice]) -> Void)?

    public init() {}

    /// **迟到的快照直接丢掉。**
    ///
    /// supervisor 是 actor，这里是 MainActor：中间隔着一次调度跳转，而它不保证顺序。
    /// 不设这道闸，一份旧快照就能把界面拽回一个已经不成立的过去
    /// （熔断已解除、图标还红着；容器已拉起、界面还说运行时不在）。
    public func apply(_ snapshot: SupervisorSnapshot) {
        guard snapshot.sequence > appliedSequence else { return }

        appliedSequence = snapshot.sequence

        let stateChanged = snapshot.state != state
        state = snapshot.state

        if let latest = snapshot.notices.last {
            lastNotice = latest
        } else if stateChanged {
            // 这条通知是**上一个状态**的说法。状态都换了它还挂在那儿，就是在撒谎。
            lastNotice = nil
        }

        // ★ 系统通知桥接（Day 8）：投这一份被采纳快照带来的 notices（P1-7：事件流，不是留存态）。
        // 在 sequence 闸之内，所以迟到的旧快照不会把它的旧 notices 再投一遍。
        if !snapshot.notices.isEmpty {
            onNotices?(snapshot.notices)
        }
    }

    /// 交给 `Supervisor` 的观测闭包。**composition root 唯一需要知道的一行。**
    ///
    /// 闭包从 actor 里同步调用，所以这里只能把工作丢回 MainActor——
    /// 于是就有了那个乱序窗口，于是就有了 `sequence`。
    public nonisolated func observer() -> @Sendable (SupervisorSnapshot) -> Void {
        { snapshot in
            Task { @MainActor in
                self.apply(snapshot)
            }
        }
    }
}
