import Foundation
import Testing

@testable import ContainerCore

/// 熔断与失败分类。**Day 4 的核心命题，也是这个 App 最容易写错的一处。**
///
/// 写错的方式很具体：熔断阈值「10 分钟内 5 次」配上「1→2→4→8→16 秒」的退避，
/// 五次失败只花 **31 秒**。而 R13 的核心场景（Mac 重启后外置盘/网络卷还没挂上）
/// 动辄要几分钟才就绪——照字面实现，supervisor 会在 31 秒后熔断放弃，
/// **正好死在它唯一该活着的那一刻**。
///
/// 所以失败必须分三档，而不是「可重试 / 不可重试」两档。
@Suite("Supervisor 熔断与失败分类")
struct SupervisorCircuitBreakerTests {

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let g1 = RuntimeGeneration(pid: 4242, startTime: 111)
    let g2 = RuntimeGeneration(pid: 4242, startTime: 222)

    /// 退避恒定 10 秒——熔断的命题是「几次、多久之内」，不是「等多久」。
    let backoff = FixedBackoff(10)
    let config = SupervisorConfig.default

    private func run(
        _ state: SupervisorState,
        _ event: SupervisorEvent,
        config: SupervisorConfig? = nil
    ) -> (SupervisorState, [SupervisorEffect]) {
        reduce(state, event, config: config ?? self.config, backoff: backoff)
    }

    /// 把状态推进 `times` 次 transient 失败（每次失败后 tick 唤醒重试）。
    private func failTransiently(times: Int, startingAt start: Date) -> SupervisorState {
        var state = SupervisorState.reconciling(generation: g1, failures: nil)
        var now = start

        for _ in 0..<times {
            (state, _) = run(state, .reconcileFinished(.failure(.transient), generation: g1, at: now))

            // 还没熔断的话，退避到期 → 重试。
            if case .cooldown(_, let until, _) = state {
                now = until
                (state, _) = run(state, .tick(now: now))
            }
        }

        return state
    }

    /// 连续 `times` 次「环境没就绪」，每次都退避到期后重试。
    ///
    /// **每一次都断言没有熔断**——不是循环跑完再看结果：R13 的命题是
    /// 「一次都不许熔断」，若只查末态，中途熔断又被后续事件救回来的实现也能骗过测试。
    ///
    /// 返回最终状态与最后一次失败的时刻（调用方要接着往下打别的失败）。
    private func failWithEnvironmentNotReady(
        times: Int,
        startingAt start: Date
    ) -> (SupervisorState, Date) {
        var state = SupervisorState.reconciling(generation: g1, failures: nil)
        var now = start

        for _ in 0..<times {
            (state, _) = run(
                state,
                .reconcileFinished(.failure(.environmentNotReady), generation: g1, at: now)
            )

            guard case .cooldown(_, let until, _) = state else {
                Issue.record("环境未就绪被判成了熔断——supervisor 在核心场景下当场报废：\(state)")
                return (state, now)
            }

            now = until
            (state, _) = run(state, .tick(now: now))
        }

        return (state, now)
    }

    // MARK: - ★ R13：环境未就绪永远不该熔断

    @Test("★ R13：mount 源路径未就绪 → 无限退避重试，永不熔断")
    func environmentNotReadyNeverTripsBreaker() {
        // 失败 20 次——远超熔断阈值（5 次）。
        let (state, _) = failWithEnvironmentNotReady(times: 20, startingAt: t0)

        // 20 次之后依然在重试。外置盘 10 分钟后挂上，容器还是会被拉起来。
        guard case .reconciling(g1, let streak) = state else {
            Issue.record("20 次环境失败后不该离开重试循环：\(state)")
            return
        }

        // 熔断计数**一次都没涨**——这是 R13 的全部要害。
        #expect(streak?.breakerCount == 0)

        // 退避档位照涨（否则会以最短间隔重试一整天）。
        #expect(streak?.attempts == 20)
    }

    @Test("★ R13：环境未就绪不计入熔断计数，不该拖累 crashloop 的判定")
    func environmentNotReadyDoesNotPolluteBreakerCount() {
        // 先来 4 次「环境没好」。
        var (state, now) = failWithEnvironmentNotReady(times: 4, startingAt: t0)

        // 再来 1 次真的 transient 失败。若前面 4 次被计进了熔断计数，
        // 这一下就会凑满 5 次触发熔断——那是错的。
        (state, _) = run(state, .reconcileFinished(.failure(.transient), generation: g1, at: now))

        guard case .cooldown(_, _, let streak) = state else {
            Issue.record("环境未就绪污染了熔断计数：\(state)")
            return
        }

        // 熔断只数这一次 transient。
        #expect(streak.breakerCount == 1)

        // 但退避档位把那 4 次环境失败也数了进去——否则外置盘不挂上时，
        // supervisor 会一直以第 1 档（最短）的间隔重试，把日志刷成瀑布。
        #expect(streak.attempts == 5)
    }

    // MARK: - 熔断（真正的 crashloop）

    @Test("窗口内连续 transient 失败达到阈值 → 熔断")
    func tripsAfterThresholdWithinWindow() {
        // 阈值默认 5：前 4 次进 cooldown，第 5 次熔断。
        var state = failTransiently(times: 4, startingAt: t0)

        // 第 4 次失败后 tick 已经把它唤回 reconciling，带着 4 次失败债。
        // 只断言次数——每次失败的确切时刻是滑动窗口的内部记账，不是这条测试的命题。
        guard case .reconciling(g1, let streak) = state else {
            Issue.record("第 4 次失败不该熔断：\(state)")
            return
        }
        #expect(streak?.breakerCount == 4)

        // 第 5 次失败 → 熔断。
        let tripAt = t0.addingTimeInterval(120)
        (state, _) = run(state, .reconcileFinished(.failure(.transient), generation: g1, at: tripAt))

        #expect(state == .circuitOpen(generation: g1, since: tripAt))
    }

    @Test("熔断时必须报警，且不再安排任何自动重试")
    func trippingNotifiesAndSchedulesNothing() {
        let state = SupervisorState.reconciling(
            generation: g1,
            failures: FailureStreak(attempts: 4, breakerFailures: Array(repeating: t0, count: 4))
        )
        let tripAt = t0.addingTimeInterval(60)

        let (next, effects) = run(
            state,
            .reconcileFinished(.failure(.transient), generation: g1, at: tripAt)
        )

        #expect(next == .circuitOpen(generation: g1, since: tripAt))
        // 熔断的全部意义就是「停下来，别再自动试了」——
        // 再吐一个 scheduleTick 出去，熔断就成了摆设。
        #expect(effects == [.notify(.circuitOpened(generation: g1, failures: 5))])
    }

    @Test("失败散落在窗口之外 → 不熔断，过期的那些被滑出窗口")
    func doesNotTripWhenFailuresAreSpreadOutsideWindow() {
        // 4 次失败都发生在 t0。
        var state = SupervisorState.reconciling(
            generation: g1,
            failures: FailureStreak(attempts: 4, breakerFailures: Array(repeating: t0, count: 4))
        )

        let wayLater = t0.addingTimeInterval(700)   // > 600s 窗口
        (state, _) = run(
            state,
            .reconcileFinished(.failure(.transient), generation: g1, at: wayLater)
        )

        // 偶发失败（比如每小时崩一次）不该被攒成 crashloop：旧的 4 次已经滑出窗口。
        guard case .cooldown(_, _, let streak) = state else {
            Issue.record("不该熔断：\(state)")
            return
        }
        #expect(streak.breakerCount == 1)
    }

    /// ★ **滑动窗口，不是翻页窗口。**（codex review 抓到的，我原来写错了。）
    ///
    /// 失败发生在 0 / 590 / 610 / 620 / 630 / 640 秒。
    /// 若窗口是「从第一次失败起算，过期就整串扔掉」，610 那次会因为距锚点 0 已过 600s
    /// 而把**仍在窗口内的 590 那次一起扔掉**——最后只数到 4 次，不熔断。
    ///
    /// 可 590→640 这 50 秒里崩了 5 次，是标准 crashloop，恰恰最该熔断。
    @Test("★ 滑动窗口：跨过锚点但彼此密集的失败，仍然要熔断")
    func slidingWindowCatchesDenseCrashloopAcrossAnchor() {
        let offsets: [TimeInterval] = [0, 590, 610, 620, 630, 640]
        var state = SupervisorState.reconciling(generation: g1, failures: nil)

        for (index, offset) in offsets.enumerated() {
            let now = t0.addingTimeInterval(offset)

            (state, _) = run(
                state,
                .reconcileFinished(.failure(.transient), generation: g1, at: now)
            )

            if case .circuitOpen = state {
                // 第 6 次（640s）时，窗口内是 590/610/620/630/640 —— 正好 5 次，熔断。
                #expect(index == offsets.count - 1)
                #expect(state == .circuitOpen(generation: g1, since: now))
                return
            }

            // 没熔断就把它从 cooldown 唤回来，继续下一次失败。
            guard case .cooldown(let generation, _, let failures) = state else {
                Issue.record("应当处于 cooldown：\(state)")
                return
            }
            state = .reconciling(generation: generation, failures: failures)
        }

        Issue.record("50 秒内崩了 5 次却没熔断——滑动窗口退化成了翻页窗口")
    }

    /// ★ **退避档位不跟着熔断窗口翻页。**（codex review 抓到的，我原来写错了。）
    ///
    /// 外置盘挂不上会持续几十分钟。退避涨到 300 秒上限后，两次失败的间隔就是 300 秒——
    /// 于是第三次失败必然撞破 600 秒的熔断窗口。
    ///
    /// 若退避档位跟着窗口一起重置，它会从上限**掉回 1 秒重新猛冲**（1,2,4,8…），
    /// 攒够 10 分钟再爆一次——**周期性爆发**，把日志刷成瀑布，
    /// 而 `.environmentNotReady`「一直试下去的成本极低」当场变成谎话。
    @Test("★ 环境长时间未就绪：退避档位单调上涨，不因窗口过期而回落")
    func backoffDoesNotResetWhenBreakerWindowExpires() {
        let realistic = ExponentialBackoff()   // 1s → … → 300s 封顶
        var state = SupervisorState.reconciling(generation: g1, failures: nil)
        var now = t0
        var lastDelay: TimeInterval = 0

        // 模拟外置盘一小时没挂上。
        for _ in 0..<30 {
            (state, _) = reduce(
                state,
                .reconcileFinished(.failure(.environmentNotReady), generation: g1, at: now),
                config: config,
                backoff: realistic
            )

            guard case .cooldown(_, let until, _) = state else {
                Issue.record("环境未就绪不该离开重试循环：\(state)")
                return
            }

            let delay = until.timeIntervalSince(now)

            // **单调不减**——一次都不许掉回去。
            #expect(delay >= lastDelay)
            lastDelay = delay

            now = until
            (state, _) = reduce(state, .tick(now: now), config: config, backoff: realistic)
        }

        // 一小时后它还在以 5 分钟的间隔安静地重试，没有爆发，也没有熔断。
        #expect(lastDelay == 300)
    }

    @Test("成功一次 → 失败债清零")
    func successClearsTheStreak() {
        let state = SupervisorState.reconciling(
            generation: g1,
            failures: FailureStreak(attempts: 4, breakerFailures: Array(repeating: t0, count: 4))
        )

        let (next, _) = run(
            state,
            .reconcileFinished(.success, generation: g1, at: t0.addingTimeInterval(30))
        )

        // 成功之后状态里不该再留任何失败债——否则一次偶然成功之后的第一次失败就熔断。
        #expect(next == .runtimeUp(generation: g1, baseline: false))
    }

    // MARK: - 熔断之后：只有人能把它救出来

    @Test("★ circuitOpen + tick → 一动不动（熔断的全部意义）")
    func circuitOpenIgnoresTick() {
        let state = SupervisorState.circuitOpen(generation: g1, since: t0)

        let (next, effects) = run(state, .tick(now: t0.addingTimeInterval(3600)))

        // 一小时后也不自动重试。绝不静默无限重试——那正是 crashloop 打铁。
        #expect(next == state)
        #expect(effects.isEmpty)
    }

    @Test("circuitOpen + 同一代 running → 一动不动")
    func circuitOpenIgnoresSameGenerationProbe() {
        let state = SupervisorState.circuitOpen(generation: g1, since: t0)

        let (next, effects) = run(state, .probed(.running(g1), at: t0.addingTimeInterval(60)))

        #expect(next == state)
        #expect(effects.isEmpty)
    }

    @Test("★ circuitOpen + 用户手动 reconcile → 唯一的出口")
    func circuitOpenUserForcedReset() {
        let state = SupervisorState.circuitOpen(generation: g1, since: t0)

        let (next, effects) = run(state, .userForcedReconcile(at: t0.addingTimeInterval(60)))

        // 用户按下按钮 = 他很可能刚修好了根因。计数清零，重新来过。
        #expect(next == .reconciling(generation: g1, failures: nil))
        #expect(effects == [.startReconcile(generation: g1)])
    }

    @Test("circuitOpen + 运行时挂了 → runtimeDown（熔断随旧世界一起作废）")
    func circuitOpenRuntimeDied() {
        let state = SupervisorState.circuitOpen(generation: g1, since: t0)

        let (next, effects) = run(state, .probed(.down, at: t0.addingTimeInterval(60)))

        #expect(next == .runtimeDown)
        #expect(effects.isEmpty)
    }

    @Test("★ circuitOpen + 换代 → 新一代不背旧一代的熔断")
    func circuitOpenGenerationChanged() {
        let state = SupervisorState.circuitOpen(generation: g1, since: t0)

        let (next, effects) = run(state, .probed(.running(g2), at: t0.addingTimeInterval(60)))

        // 运行时重启了。上一代的 crashloop 很可能正是运行时自己病了导致的——
        // 让新一代继承那个熔断，等于 apiserver 一崩就再也不管容器了。
        #expect(next == .reconciling(generation: g2, failures: nil))
        #expect(effects == [.startReconcile(generation: g2)])
    }

    @Test("circuitOpen + 迟到的 reconcileFinished → 丢弃")
    func circuitOpenIgnoresFinished() {
        let state = SupervisorState.circuitOpen(generation: g1, since: t0)

        let (next, effects) = run(
            state,
            .reconcileFinished(.success, generation: g1, at: t0.addingTimeInterval(5))
        )

        #expect(next == state)
        #expect(effects.isEmpty)
    }

    // MARK: - permanent：重试一万次也没用

    @Test("★ permanent 失败 → 不重试、不退避、不熔断，直接报给用户")
    func permanentFailureIsReportedNotRetried() {
        let state = SupervisorState.reconciling(generation: g1, failures: nil)

        let (next, effects) = run(
            state,
            .reconcileFinished(.failure(.permanent), generation: g1, at: t0)
        )

        // 容器不存在（白名单 ID 拼错了、或者容器被 container delete 删了）——
        // 退避重试是在对着一个永远不会出现的容器无限重试。
        #expect(next == .runtimeUp(generation: g1, baseline: false))
        #expect(effects == [.notify(.reconcileAbandoned(generation: g1))])
    }

    @Test("permanent 失败不计入熔断计数")
    func permanentFailureDoesNotCountTowardBreaker() {
        let state = SupervisorState.reconciling(
            generation: g1,
            failures: FailureStreak(attempts: 4, breakerFailures: Array(repeating: t0, count: 4))
        )

        let (next, _) = run(
            state,
            .reconcileFinished(.failure(.permanent), generation: g1, at: t0.addingTimeInterval(10))
        )

        // 已经 4 次了，但 permanent 不是 crashloop 的证据——它是配置错误。
        // 让它凑满第 5 次去触发熔断，是把两种完全不同的故障混为一谈。
        #expect(next == .runtimeUp(generation: g1, baseline: false))
    }

    // MARK: - 阈值与窗口可配

    /// ★ **`threshold = 0` 不能变成「一失败就熔断」。**（altitude review 抓到的。）
    ///
    /// 熔断判据是 `breakerCount >= threshold`，而 `.environmentNotReady` 的
    /// `breakerCount` 是 **0**——`0 >= 0` 为**真**。于是 threshold 填 0 时，
    /// 「外置盘还没挂上」的第一次失败就直接熔断，**R13 被边界值整个绕开**。
    ///
    /// 而填 0 的人多半以为那是「关闭熔断」。
    @Test("★ threshold 填 0（以为是「关掉熔断」）不能让环境未就绪秒死")
    func zeroThresholdDoesNotTripOnEnvironmentNotReady() {
        let broken = SupervisorConfig(circuitBreakerThreshold: 0)

        // config 把它夹回了合法区间，非法值表达不出来。
        #expect(broken.circuitBreakerThreshold >= 1)

        let (state, _) = run(
            .reconciling(generation: g1, failures: nil),
            .reconcileFinished(.failure(.environmentNotReady), generation: g1, at: t0),
            config: broken
        )

        guard case .cooldown = state else {
            Issue.record("threshold=0 让环境未就绪秒熔断——R13 当场报废：\(state)")
            return
        }
    }

    /// ★ **`window = 0` 不能让熔断永远打不开。**（altitude review 抓到的。）
    ///
    /// 滑动窗口会把所有历史都过滤掉，`breakerCount` 永远追不上阈值——
    /// 真正的 crashloop 被无限放行，而用户以为熔断这道安全网还在。
    @Test("★ window 填 0 不能让熔断永远失效")
    func zeroWindowStillTrips() {
        let broken = SupervisorConfig(circuitBreakerWindow: 0)

        #expect(broken.circuitBreakerWindow > 0)

        // 同一毫秒内连崩 5 次（最极端的 crashloop）——必须熔断。
        var state = SupervisorState.reconciling(generation: g1, failures: nil)

        for _ in 0..<5 {
            (state, _) = run(
                state,
                .reconcileFinished(.failure(.transient), generation: g1, at: t0),
                config: broken
            )

            if case .circuitOpen = state { return }

            guard case .cooldown(let generation, _, let failures) = state else {
                Issue.record("应当处于 cooldown：\(state)")
                return
            }
            state = .reconciling(generation: generation, failures: failures)
        }

        Issue.record("瞬间连崩 5 次却没熔断——window=0 让滑动窗口退化成了空集")
    }

    @Test("熔断阈值与窗口来自 config，不是写死的魔数")
    func thresholdAndWindowAreConfigurable() {
        let strict = SupervisorConfig(
            circuitBreakerThreshold: 2,
            circuitBreakerWindow: 60
        )

        var state = SupervisorState.reconciling(generation: g1, failures: nil)

        (state, _) = run(
            state,
            .reconcileFinished(.failure(.transient), generation: g1, at: t0),
            config: strict
        )
        guard case .cooldown = state else {
            Issue.record("第 1 次不该熔断：\(state)")
            return
        }

        (state, _) = run(state, .tick(now: t0.addingTimeInterval(10)), config: strict)

        let tripAt = t0.addingTimeInterval(20)
        (state, _) = run(
            state,
            .reconcileFinished(.failure(.transient), generation: g1, at: tripAt),
            config: strict
        )

        #expect(state == .circuitOpen(generation: g1, since: tripAt))
    }
}
