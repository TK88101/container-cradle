import Foundation
import Testing

@testable import ContainerCore

/// 转移表的**机械翻译**——一格一个 `@Test`，断言「下一个状态」与「产出的 effects」两者。
///
/// 只断言状态不断言 effects 是不够的：「运行时换代了要去拉容器」这个命题的**全部内容**
/// 就在 effect 里。状态转成 `.reconciling` 却没吐出 `startReconcile`，
/// 状态机看起来完全正确，而容器一个都不会被拉起来——那正是本 App 唯一的价值。
///
/// 时间全是常量。**没有 sleep、没有真实时钟**：「退避已到期」和「还没到点」
/// 是两个必然被触发的分支，不是靠撞运气撞出来的。
@Suite("SupervisorState reducer（转移表）")
struct SupervisorReducerTests {

    // MARK: - 固定装置

    /// 假时钟的原点。具体数值无意义，只要求测试内一致。
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 第一代运行时。
    let g1 = RuntimeGeneration(pid: 4242, startTime: 111)

    /// 第二代。**pid 故意与 g1 相同**——这正是 `RuntimeGeneration` 要 `startTime` 的理由：
    /// apiserver 挂了重起，系统把同一个 pid 分了回来。只比 pid 会把这次换代**整个漏掉**。
    let g2 = RuntimeGeneration(pid: 4242, startTime: 222)

    /// 恒定 30 秒。转移测试里没有一个数字来自退避曲线（曲线本身是 Day 4 的命题）。
    let backoff = FixedBackoff(30)

    let config = SupervisorConfig.default

    /// 一串**全是 crashloop 型**（`.transient`）的失败——退避档位与熔断计数同步上涨。
    ///
    /// 转移表关心的是「失败债有没有被正确地带走 / 清零」，不关心它由哪种失败凑成。
    /// 三档失败各自的差别（尤其 `.environmentNotReady` 不计熔断）是熔断那批测试的命题。
    private func crashes(_ n: Int, since: Date) -> FailureStreak {
        FailureStreak(attempts: n, breakerFailures: Array(repeating: since, count: n))
    }

    /// 把 `reduce` 的四个参数收成一个，让每条测试只剩「给什么 → 得什么」。
    private func run(
        _ state: SupervisorState,
        _ event: SupervisorEvent,
        config: SupervisorConfig? = nil
    ) -> (SupervisorState, [SupervisorEffect]) {
        reduce(state, event, config: config ?? self.config, backoff: backoff)
    }

    // MARK: - .unknown（冷启动）

    @Test("unknown + 探到 running → baseline，且刻意不 reconcile")
    func unknownProbedRunning() {
        let (state, effects) = run(.unknown, .probed(.running(g1), at: t0))

        #expect(state == .runtimeUp(generation: g1, baseline: true))
        // 冷启动时容器停着，可能是用户 5 分钟前手动停下来正在调试的。拉起 = 和他对着干。
        #expect(effects.isEmpty)
    }

    @Test("unknown + 探到 running + 用户开了 reconcileOnLaunch → 才 reconcile")
    func unknownProbedRunningWithLaunchReconcile() {
        let (state, effects) = run(
            .unknown,
            .probed(.running(g1), at: t0),
            config: SupervisorConfig(reconcileOnLaunch: true)
        )

        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("unknown + 探到 down → runtimeDown（下一次 running 走正常边沿，核心场景不受影响）")
    func unknownProbedDown() {
        let (state, effects) = run(.unknown, .probed(.down, at: t0))

        #expect(state == .runtimeDown)
        #expect(effects.isEmpty)
    }

    @Test("unknown + 手动 reconcile → 没有运行时可拉，必须明说没做")
    func unknownForced() {
        let (state, effects) = run(.unknown, .userForcedReconcile(at: t0))

        #expect(state == .unknown)
        // 静默吞掉 = 用户以为按钮坏了，然后点第二次、第三次。
        #expect(effects == [.notify(.forcedReconcileUnavailable)])
    }

    // MARK: - .runtimeDown

    @Test("★ runtimeDown + 探到 running → 这就是本 App 存在的理由：拉起白名单容器")
    func runtimeDownProbedRunning() {
        let (state, effects) = run(.runtimeDown, .probed(.running(g1), at: t0))

        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("runtimeDown + 又探到 down → 稳态，不刷屏")
    func runtimeDownProbedDown() {
        let (state, effects) = run(.runtimeDown, .probed(.down, at: t0))

        #expect(state == .runtimeDown)
        #expect(effects.isEmpty)
    }

    @Test("runtimeDown + 手动 reconcile → 运行时都不在，拉不了")
    func runtimeDownForced() {
        let (state, effects) = run(.runtimeDown, .userForcedReconcile(at: t0))

        #expect(state == .runtimeDown)
        #expect(effects == [.notify(.forcedReconcileUnavailable)])
    }

    // MARK: - .runtimeUp

    @Test("runtimeUp + 同一代 running → 稳态（最高频路径，必须一动不动）")
    func runtimeUpSameGeneration() {
        let (state, effects) = run(
            .runtimeUp(generation: g1, baseline: true),
            .probed(.running(g1), at: t0)
        )

        #expect(state == .runtimeUp(generation: g1, baseline: true))
        #expect(effects.isEmpty)
    }

    @Test("★ D3：runtimeUp + 换代（两次都是 running，中间死过一次）→ 必须 reconcile")
    func runtimeUpGenerationChanged() {
        let (state, effects) = run(
            .runtimeUp(generation: g1, baseline: false),
            .probed(.running(g2), at: t0)
        )

        // 纯边沿检测（down→running）在这里**什么都看不见**：两次探测都是 running。
        // 运行时在两次轮询之间快速重启完了，容器全没了，supervisor 会静默失效——
        // 且永远不会自愈，因为它在等一个不会再来的边沿。令牌把它救了回来。
        #expect(state == .reconciling(generation: g2, failures: nil))
        #expect(effects == [.startReconcile(generation: g2)])
    }

    @Test("runtimeUp + 探到 down → runtimeDown")
    func runtimeUpProbedDown() {
        let (state, effects) = run(
            .runtimeUp(generation: g1, baseline: false),
            .probed(.down, at: t0)
        )

        #expect(state == .runtimeDown)
        #expect(effects.isEmpty)
    }

    @Test("runtimeUp + 手动 reconcile → 立即拉（菜单里那个「立即启动」按钮）")
    func runtimeUpForced() {
        let (state, effects) = run(
            .runtimeUp(generation: g1, baseline: true),
            .userForcedReconcile(at: t0)
        )

        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("runtimeUp + 迟到的 reconcileFinished → 不在 reconcile 中，结果无处安放，丢弃")
    func runtimeUpIgnoresFinished() {
        let (state, effects) = run(
            .runtimeUp(generation: g1, baseline: false),
            .reconcileFinished(.success, generation: g1, at: t0)
        )

        #expect(state == .runtimeUp(generation: g1, baseline: false))
        #expect(effects.isEmpty)
    }

    @Test("runtimeUp + tick → 只有 cooldown 关心 tick")
    func runtimeUpIgnoresTick() {
        let (state, effects) = run(
            .runtimeUp(generation: g1, baseline: false),
            .tick(now: t0)
        )

        #expect(state == .runtimeUp(generation: g1, baseline: false))
        #expect(effects.isEmpty)
    }

    // MARK: - .reconciling

    @Test("reconciling + 本代成功 → runtimeUp(baseline: false)")
    func reconcilingSucceeded() {
        let (state, effects) = run(
            .reconciling(generation: g1, failures: nil),
            .reconcileFinished(.success, generation: g1, at: t0)
        )

        #expect(state == .runtimeUp(generation: g1, baseline: false))
        #expect(effects == [.notify(.reconcileSucceeded(generation: g1))])
    }

    @Test("reconciling + 本代失败 → cooldown，且必须自己安排叫醒")
    func reconcilingFailed() {
        let (state, effects) = run(
            .reconciling(generation: g1, failures: nil),
            .reconcileFinished(.failure(.transient), generation: g1, at: t0)
        )

        let retryAt = t0.addingTimeInterval(30)

        #expect(state == .cooldown(generation: g1, until: retryAt, failures: crashes(1, since: t0)))
        // scheduleTick 不能省：稳态下 probe 全是同一代 running，reducer 对它们一律不动作，
        // 没人会把 cooldown 叫醒——容器就永远停在那儿了。
        #expect(effects == [
            .notify(.reconcileFailed(
                generation: g1,
                kind: .transient,
                attempt: 1,
                retryAt: retryAt
            )),
            .scheduleTick(at: retryAt),
        ])
    }

    /// ★ 上一代的结果回来了——**不论成败一律丢弃**。
    ///
    /// 为 g1 发起的 reconcile 跑到一半，运行时又换代了，状态已推进到 `.reconciling(g2)`。
    /// g1 的结果此刻回来：它描述的是一个**已经不存在的世界**。
    /// 若信了它，状态会被写成 `.runtimeUp(g1)`，而 g2 那一代的容器再也没人管。
    /// 这正是 `ContainerListStore`「旧刷新覆盖新刷新」在状态机里的同构。
    ///
    /// 成功和失败合成一条参数化测试，而不是两条：reducer 的 stale 判定是一条 `guard`，
    /// 它在 `outcome` 参与任何分支**之前**就短路返回了——两个 case 打的是**同一格**，
    /// 拆成两条测试不会多覆盖一行代码，只会让人以为覆盖了两格。
    @Test(
        "★ reconciling + 上一代的结果回来（无论成败）→ stale，必须丢弃",
        arguments: [ReconcileOutcome.success, .failure(.transient)]
    )
    func reconcilingIgnoresStaleResult(outcome: ReconcileOutcome) {
        let (state, effects) = run(
            .reconciling(generation: g2, failures: nil),
            .reconcileFinished(outcome, generation: g1, at: t0)
        )

        #expect(state == .reconciling(generation: g2, failures: nil))
        #expect(effects.isEmpty)
    }

    @Test("reconciling + 同一代 running → reconcile 还在跑，轮询别打扰它")
    func reconcilingSameGenerationProbe() {
        let (state, effects) = run(
            .reconciling(generation: g1, failures: nil),
            .probed(.running(g1), at: t0)
        )

        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects.isEmpty)
    }

    @Test("★ reconciling + 拉到一半又换代 → 作废旧的，为新一代重来")
    func reconcilingGenerationChanged() {
        let (state, effects) = run(
            .reconciling(generation: g1, failures: nil),
            .probed(.running(g2), at: t0)
        )

        #expect(state == .reconciling(generation: g2, failures: nil))
        // 顺序有意义：先作废旧的，再起新的。
        #expect(effects == [
            .cancelReconcile(generation: g1),
            .startReconcile(generation: g2),
        ])
    }

    @Test("reconciling + 运行时当场没了 → 停手（继续拉是对着空气喊话）")
    func reconcilingRuntimeDied() {
        let (state, effects) = run(
            .reconciling(generation: g1, failures: nil),
            .probed(.down, at: t0)
        )

        #expect(state == .runtimeDown)
        #expect(effects == [.cancelReconcile(generation: g1)])
    }

    @Test("reconciling + 手动 reconcile → 已经在做了，不重复下达")
    func reconcilingForced() {
        let (state, effects) = run(
            .reconciling(generation: g1, failures: nil),
            .userForcedReconcile(at: t0)
        )

        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects.isEmpty)
    }

    // MARK: - .cooldown

    @Test("cooldown + tick 到点 → 重试")
    func cooldownTickDue() {
        let until = t0.addingTimeInterval(30)
        let (state, effects) = run(
            .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)),
            .tick(now: until)
        )

        // 边界值：now == until 就算到点（不是严格大于）。tick 可能因线程调度晚到几毫秒，
        // 用严格大于会让它白白多睡一整轮。
        //
        // ★ 失败计数必须被带进新一轮（priorFailures: 1）。丢了它，下一次失败又从 attempt 1
        // 算起——指数退避永远停在第一档，熔断永远等不到阈值，crashloop 无限打铁。
        #expect(state == .reconciling(generation: g1, failures: crashes(1, since: t0)))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("cooldown + tick 已过点 → 重试")
    func cooldownTickPastDue() {
        let until = t0.addingTimeInterval(30)
        let (state, effects) = run(
            .cooldown(generation: g1, until: until, failures: crashes(2, since: t0)),
            .tick(now: until.addingTimeInterval(1))
        )

        #expect(state == .reconciling(generation: g1, failures: crashes(2, since: t0)))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("cooldown + tick 没到点 → 接着等")
    func cooldownTickNotDue() {
        let until = t0.addingTimeInterval(30)
        let (state, effects) = run(
            .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)),
            .tick(now: until.addingTimeInterval(-1))
        )

        #expect(state == .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)))
        #expect(effects.isEmpty)
    }

    @Test("cooldown + 运行时挂了 → 退避计数作废（等它回来是全新局面）")
    func cooldownRuntimeDied() {
        let (state, effects) = run(
            .cooldown(generation: g1, until: t0.addingTimeInterval(30), failures: crashes(3, since: t0)),
            .probed(.down, at: t0)
        )

        #expect(state == .runtimeDown)
        #expect(effects.isEmpty)
    }

    @Test("cooldown + 换代 → 立刻为新一代重来，不继承旧的退避")
    func cooldownGenerationChanged() {
        let (state, effects) = run(
            .cooldown(generation: g1, until: t0.addingTimeInterval(30), failures: crashes(3, since: t0)),
            .probed(.running(g2), at: t0)
        )

        #expect(state == .reconciling(generation: g2, failures: nil))
        #expect(effects == [.startReconcile(generation: g2)])
    }

    @Test("cooldown + 同一代 running → 老实等 tick")
    func cooldownSameGenerationProbe() {
        let until = t0.addingTimeInterval(30)
        let (state, effects) = run(
            .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)),
            .probed(.running(g1), at: t0)
        )

        #expect(state == .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)))
        #expect(effects.isEmpty)
    }

    @Test("cooldown + 手动 reconcile → 跳过等待立刻重试（手动兜底的核心用途）")
    func cooldownForced() {
        let (state, effects) = run(
            .cooldown(generation: g1, until: t0.addingTimeInterval(300), failures: crashes(5, since: t0)),
            .userForcedReconcile(at: t0)
        )

        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("cooldown + 迟到的 reconcileFinished → 不在 reconcile 中，丢弃")
    func cooldownIgnoresFinished() {
        let until = t0.addingTimeInterval(30)
        let (state, effects) = run(
            .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)),
            .reconcileFinished(.success, generation: g1, at: t0)
        )

        #expect(state == .cooldown(generation: g1, until: until, failures: crashes(1, since: t0)))
        #expect(effects.isEmpty)
    }

    // MARK: - 跨事件的性质（一格一格看不出来的东西）

    @Test("连续失败 → attempt 递增")
    func attemptIncrementsAcrossFailures() {
        var state = SupervisorState.reconciling(generation: g1, failures: nil)

        (state, _) = run(state, .reconcileFinished(.failure(.transient), generation: g1, at: t0))
        #expect(state == .cooldown(generation: g1, until: t0.addingTimeInterval(30), failures: crashes(1, since: t0)))

        // 退避到期，重试——但**背着那 1 次失败**进去。
        (state, _) = run(state, .tick(now: t0.addingTimeInterval(30)))
        #expect(state == .reconciling(generation: g1, failures: crashes(1, since: t0)))

        let t1 = t0.addingTimeInterval(35)
        (state, _) = run(state, .reconcileFinished(.failure(.transient), generation: g1, at: t1))

        // 只断言次数与到期时刻——**不断言每次失败的时间戳具体是几点**。
        // 那是熔断滑动窗口的内部记账，跟「失败债有没有被带走」这个命题无关；
        // 写死它只会让这条测试在窗口实现变动时假红。
        guard case .cooldown(g1, let until, let failures) = state else {
            Issue.record("第二次失败后应当回到 cooldown：\(state)")
            return
        }
        #expect(until == t1.addingTimeInterval(30))
        #expect(failures.attempts == 2)
        #expect(failures.breakerCount == 2)
    }

    @Test("★ 换代后 attempt 清零：新一代不该背上一代的失败债")
    func attemptResetsOnGenerationChange() {
        // 上一代已经失败了 3 次（很可能正是因为它快死了）。
        let state = SupervisorState.cooldown(
            generation: g1,
            until: t0.addingTimeInterval(300),
            failures: crashes(3, since: t0)
        )

        let (afterChange, _) = run(state, .probed(.running(g2), at: t0))
        #expect(afterChange == .reconciling(generation: g2, failures: nil))

        // 新一代第一次失败 → attempt 必须是 1，不是 4。
        // 若继承旧计数，Day 4 的熔断会在新一代刚起步时就把它判死。
        let (afterFailure, _) = run(
            afterChange,
            .reconcileFinished(.failure(.transient), generation: g2, at: t0)
        )
        #expect(afterFailure == .cooldown(
            generation: g2,
            until: t0.addingTimeInterval(30),
            failures: crashes(1, since: t0)
        ))
    }

    @Test("★ 核心场景全链路：Mac 重启 → 运行时回来 → 容器被拉起")
    func coreScenarioEndToEnd() {
        // app 由 SMAppService 登录自启，早于或并行于 apiserver → 先看到 down。
        var state = SupervisorState.unknown
        var effects: [SupervisorEffect] = []

        (state, effects) = run(state, .probed(.down, at: t0))
        #expect(state == .runtimeDown)
        #expect(effects.isEmpty)

        // apiserver 起来了。
        (state, effects) = run(state, .probed(.running(g1), at: t0.addingTimeInterval(5)))
        #expect(state == .reconciling(generation: g1, failures: nil))
        #expect(effects == [.startReconcile(generation: g1)])   // ← 官方 CLI 给不了的那一下

        (state, effects) = run(
            state,
            .reconcileFinished(.success, generation: g1, at: t0.addingTimeInterval(12))
        )
        #expect(state == .runtimeUp(generation: g1, baseline: false))
        #expect(effects == [.notify(.reconcileSucceeded(generation: g1))])
    }

    @Test("纯函数：同一个 (state, event) 喂两次，结果完全相同")
    func isPure() {
        let state = SupervisorState.reconciling(generation: g1, failures: nil)
        let event = SupervisorEvent.probed(.running(g2), at: t0)

        let first = run(state, event)
        let second = run(state, event)

        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }
}
