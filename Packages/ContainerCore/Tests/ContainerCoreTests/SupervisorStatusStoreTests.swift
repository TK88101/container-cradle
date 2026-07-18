import Foundation
import Testing

@testable import ContainerCore

/// **UI 与 supervisor 之间那根线，本身就是一个跨 `await` 的窗口。**
///
/// supervisor 是 actor，UI store 是 `@MainActor`——快照从前者到后者必然经过一次
/// 调度跳转，而**跳转不保证顺序**。这个仓库已经在「跨 await 之后世界变了」上栽过三次
/// （`ContainerListStore` / reducer / `Supervisor.stop`）。这里是第四个同形状的窗口，
/// 所以快照带 `sequence`，store 只认更新的那一份。
@Suite("SupervisorStatusStore")
@MainActor
struct SupervisorStatusStoreTests {

    private let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)
    private let g2 = RuntimeGeneration(pid: 200, startTime: 2_000)

    @Test("按序到达：状态与通知都落地")
    func appliesInOrder() {
        let store = SupervisorStatusStore()

        store.apply(SupervisorSnapshot(state: .runtimeDown, notices: [], sequence: 1))
        #expect(store.state == .runtimeDown)

        store.apply(
            SupervisorSnapshot(
                state: .runtimeUp(generation: g1, baseline: false),
                notices: [.reconcileSucceeded(generation: g1)],
                sequence: 2
            )
        )

        #expect(store.state == .runtimeUp(generation: g1, baseline: false))
        #expect(store.lastNotice == .reconcileSucceeded(generation: g1))
    }

    /// ★ 乱序的旧快照**必须被丢掉**。
    ///
    /// 不丢的话，UI 会显示一个**已经不成立的过去**：熔断已经解除了，菜单栏还挂着红色警告；
    /// 或者更糟——容器已经拉起来了，界面还停在「运行时不在」。
    @Test("乱序到达：旧快照被丢弃，不覆盖新状态")
    func dropsStaleSnapshot() {
        let store = SupervisorStatusStore()

        store.apply(
            SupervisorSnapshot(
                state: .runtimeUp(generation: g2, baseline: false),
                notices: [.reconcileSucceeded(generation: g2)],
                sequence: 7
            )
        )

        // 迟到的旧快照（seq 更小）——一个字都不许写进去。
        store.apply(
            SupervisorSnapshot(
                state: .runtimeDown,
                notices: [.circuitOpened(generation: g1, failures: 5)],
                sequence: 3
            )
        )

        #expect(store.state == .runtimeUp(generation: g2, baseline: false))
        #expect(store.lastNotice == .reconcileSucceeded(generation: g2))
    }

    /// 同一个 sequence 重复投递（重试 / 重复注册观测者）也不该动状态。
    @Test("重复 sequence：幂等")
    func duplicateSequenceIsIdempotent() {
        let store = SupervisorStatusStore()

        store.apply(SupervisorSnapshot(state: .runtimeDown, notices: [], sequence: 1))
        store.apply(SupervisorSnapshot(state: .unknown, notices: [], sequence: 1))

        #expect(store.state == .runtimeDown)
    }

    /// **状态没变的那些轮次，通知要留着。**
    ///
    /// `.cooldown` 里轮询一直在跑，每一轮 probe 都产出一份「状态照旧、没有通知」的快照。
    /// 若这些快照把通知抹掉，用户在漫长的退避里只看得到「等待重试」，
    /// 看不到「因为外置盘还没挂上」——而后者才是他该去做点什么的那条信息。
    @Test("状态未变的空快照：通知留着")
    func noticeSurvivesWhileStateUnchanged() {
        let store = SupervisorStatusStore()
        let cooldown = SupervisorState.cooldown(
            generation: g1,
            until: Date(timeIntervalSince1970: 60),
            failures: FailureStreak(attempts: 1, breakerFailures: [])
        )

        store.apply(
            SupervisorSnapshot(
                state: cooldown,
                notices: [
                    .reconcileFailed(
                        generation: g1,
                        kind: .environmentNotReady,
                        attempt: 1,
                        retryAt: Date(timeIntervalSince1970: 60)
                    )
                ],
                sequence: 1
            )
        )

        // 退避期间的例行 probe：状态照旧，没有新通知。
        store.apply(SupervisorSnapshot(state: cooldown, notices: [], sequence: 2))

        #expect(
            store.lastNotice
                == .reconcileFailed(
                    generation: g1,
                    kind: .environmentNotReady,
                    attempt: 1,
                    retryAt: Date(timeIntervalSince1970: 60)
                )
        )
    }

    /// ★★ **状态变了、又没带新通知 → 旧通知已经不成立了，必须清掉**
    /// （codex review 第三轮抓到的，推翻了我原本「通知一直留着」的规则）。
    ///
    /// 熔断之后用户按了「立即启动受管容器」→ 状态变成 `.reconciling`，这一轮不带通知。
    /// 旧通知若留着，界面上就同时写着「正在拉起受管容器…」和「已停止自动重试」——
    /// 两行字互相矛盾，而且底下那行**是假的**：它此刻正在拉。
    @Test("状态变了且无新通知：旧通知清掉，不许和新状态互相打脸")
    func staleNoticeIsClearedWhenStateMovesOn() {
        let store = SupervisorStatusStore()

        store.apply(
            SupervisorSnapshot(
                state: .circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 10)),
                notices: [.circuitOpened(generation: g1, failures: 5)],
                sequence: 1
            )
        )
        #expect(store.lastNotice == .circuitOpened(generation: g1, failures: 5))

        // 用户按了「立即启动受管容器」——熔断的唯一出口。
        store.apply(
            SupervisorSnapshot(
                state: .reconciling(generation: g1, failures: nil),
                notices: [],
                sequence: 2
            )
        )

        #expect(store.state == .reconciling(generation: g1, failures: nil))
        #expect(store.lastNotice == nil)
    }

    // MARK: - Day 8：onNotices 事件流（系统通知桥接的输入）

    /// 被采纳的快照带来的 notices，原样投给 `onNotices`——系统通知桥接消费的是这条流。
    @Test("onNotices：投出这一份快照的 notices")
    func onNoticesFiresWithSnapshotNotices() {
        let store = SupervisorStatusStore()
        var received: [[SupervisorNotice]] = []
        store.onNotices = { received.append($0) }

        store.apply(
            SupervisorSnapshot(
                state: .circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 10)),
                notices: [.circuitOpened(generation: g1, failures: 5)],
                sequence: 1
            )
        )

        #expect(received == [[.circuitOpened(generation: g1, failures: 5)]])
    }

    /// ★ 迟到的旧快照被 sequence 闸拦下 → 它的 notices **不投**（否则会重弹一条过期的熔断）。
    @Test("onNotices：被丢弃的旧快照不投它的 notices")
    func onNoticesSkipsStaleSnapshot() {
        let store = SupervisorStatusStore()
        var received: [[SupervisorNotice]] = []
        store.onNotices = { received.append($0) }

        store.apply(SupervisorSnapshot(state: .runtimeDown, notices: [], sequence: 7))
        // 迟到的旧快照（seq 更小）带着一条熔断——不许被投出去。
        store.apply(
            SupervisorSnapshot(
                state: .circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 10)),
                notices: [.circuitOpened(generation: g1, failures: 5)],
                sequence: 3
            )
        )

        #expect(received.isEmpty)
    }
}
