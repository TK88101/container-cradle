import Foundation

/// **supervisor 的大脑。纯函数：零 IO、零时钟、零 `Task`。**
///
/// 副作用只被**描述**（返回 `[SupervisorEffect]`），执行是 `Supervisor` actor（Day 5）的事。
/// 于是「运行时换代时有没有下达 reconcile」变成一个对返回值的断言——
/// 不用起容器、不用等异步、不用真实时间。这台状态机 100% 可单测正是从这一条来的。
///
/// ## 三条贯穿全表的规矩
///
/// 1. **时间只从事件来。** 这里不出现 `Date()`。
/// 2. **`reconcileFinished` 必须验令牌。** 它是异步结果回写；不是当前这一代的结果一律丢弃。
///    （`ContainerListStore` 的「旧刷新覆盖新刷新」是同一个坑。）
/// 3. **换代 = 全新局面。** 退避计数清零、在途 reconcile 作废。
///    新一代不背上一代的失败债——否则 Day 4 的熔断会在它刚起步时就判它死刑。
public func reduce(
    _ state: SupervisorState,
    _ event: SupervisorEvent,
    config: SupervisorConfig,
    backoff: any BackoffPolicy
) -> (SupervisorState, [SupervisorEffect]) {
    switch event {
    case .probed(let result, _):
        probed(state, result, config: config)

    case .reconcileFinished(let outcome, let generation, let now):
        reconcileFinished(
            state,
            outcome: outcome,
            generation: generation,
            now: now,
            config: config,
            backoff: backoff
        )

    case .tick(let now):
        tick(state, now: now)

    case .userForcedReconcile:
        userForcedReconcile(state)
    }
}

// MARK: - probed

private func probed(
    _ state: SupervisorState,
    _ result: ProbeResult,
    config: SupervisorConfig
) -> (SupervisorState, [SupervisorEffect]) {
    switch result {
    case .down:
        runtimeWentDown(from: state)

    case .running(let probed):
        runtimeIsRunning(state, generation: probed, config: config)
    }
}

/// 运行时不在了。
///
/// 所有状态一律收敛到 `.runtimeDown`——**这不是偷懒，是刻意的**：
/// 退避计数、在途 reconcile 全部作废。运行时回来时是全新一代，
/// 旧的一切（等到一半的退避、拉到一半的容器）都是在描述一个已经消失的世界。
private func runtimeWentDown(from state: SupervisorState) -> (SupervisorState, [SupervisorEffect]) {
    switch state {
    case .runtimeDown:
        // 稳态。重复探测不该刷屏。
        (.runtimeDown, [])

    case .reconciling(let generation, _):
        // 正拉到一半运行时就没了。继续拉是对着空气喊话。
        (.runtimeDown, [.cancelReconcile(generation: generation)])

    case .unknown, .runtimeUp, .cooldown, .circuitOpen:
        // 熔断也在这里作废——它描述的是「上一代那个运行时里的容器一直崩」，
        // 而那个运行时已经没了。见 `.circuitOpen` 的文档：熔断不是终身监禁。
        (.runtimeDown, [])
    }
}

/// 运行时在跑。**全表最要紧的一格在这里**：`.runtimeUp` / `.reconciling` / `.cooldown`
/// 看到一个**不同的令牌**，都意味着运行时在我们眼皮底下死过一次（D3）。
private func runtimeIsRunning(
    _ state: SupervisorState,
    generation probed: RuntimeGeneration,
    config: SupervisorConfig
) -> (SupervisorState, [SupervisorEffect]) {
    switch state {
    case .unknown:
        // 冷启动，apiserver 本来就在跑。**默认不 reconcile**：容器停着可能是用户
        // 5 分钟前手动停下来正在调试的，一启动就拉起是在和他对着干。
        // 核心场景（Mac 重启 / apiserver 崩了）不走这条路——那时 app 先看到 .runtimeDown。
        if config.reconcileOnLaunch {
            (freshReconcile(probed), [.startReconcile(generation: probed)])
        } else {
            (.runtimeUp(generation: probed, baseline: true), [])
        }

    case .runtimeDown:
        // ★ 它回来了。这一下就是整个 App 存在的理由。
        (freshReconcile(probed), [.startReconcile(generation: probed)])

    case .runtimeUp(let current, _):
        if current == probed {
            // 稳态，最高频的一格。**返回 state 本身**而不是重建同一个 case：
            // 重建是在重复描述已知事实，且哪天给 .runtimeUp 加个字段，
            // 手写的重建会悄悄漏掉它。
            (state, [])
        } else {
            // ★ D3：两次探测都是 running，但令牌变了 → 中间必然死过一次。
            // 纯边沿检测在这里什么都看不见，容器却已经全停了。
            (freshReconcile(probed), [.startReconcile(generation: probed)])
        }

    case .reconciling(let current, _):
        if current == probed {
            // 同一代，reconcile 还在跑。轮询别打扰它。
            (state, [])
        } else {
            // 拉到一半又换代了：在途那次拉的是**上一代的容器**，作废，为新一代重来。
            (
                freshReconcile(probed),
                [
                    .cancelReconcile(generation: current),
                    .startReconcile(generation: probed),
                ]
            )
        }

    case .cooldown(let current, _, _):
        if current == probed {
            // 同一代，老实等 tick。
            (state, [])
        } else {
            // 换代 = 全新局面：**不继承退避计数**，立刻重来。
            (freshReconcile(probed), [.startReconcile(generation: probed)])
        }

    case .circuitOpen(let current, _):
        if current == probed {
            // 同一代，还在熔断中。**一动不动**——这正是熔断的意义。
            (state, [])
        } else {
            // ★ 换代 → 熔断作废。上一代的 crashloop 很可能正是运行时自己病了导致的；
            // 让新一代继承那个熔断，等于 apiserver 一崩，supervisor 就再也不管容器了。
            (freshReconcile(probed), [.startReconcile(generation: probed)])
        }
    }
}

/// 为一个全新的一代开始 reconcile：**失败债一笔勾销**。
///
/// 新一代不背上一代的债。上一代失败 3 次很可能正是因为它快死了——
/// 让新一代继承这笔债，熔断会在它刚起步时就把它判死。
private func freshReconcile(_ generation: RuntimeGeneration) -> SupervisorState {
    .reconciling(generation: generation, failures: nil)
}

// MARK: - reconcileFinished

/// 一次 reconcile 结束了。
///
/// **只有 `.reconciling(同一代)` 才接受这个结果。** 其余一律丢弃：
/// - 上一代的结果（stale）——它描述的是一个已经不存在的世界，信了它就等于把状态
///   写回旧一代，而新一代的容器再也没人管；
/// - 不在 `.reconciling` 时收到的结果——我们已经 `cancelReconcile` 过了，
///   而 cancel 的语义是**作废**不是**中止**（底层没有取消语义，旧 reconcile 照跑完），
///   所以这条迟到的结果是预期之内的，不是异常。
private func reconcileFinished(
    _ state: SupervisorState,
    outcome: ReconcileOutcome,
    generation: RuntimeGeneration,
    now: Date,
    config: SupervisorConfig,
    backoff: any BackoffPolicy
) -> (SupervisorState, [SupervisorEffect]) {
    guard case .reconciling(let current, let failures) = state, current == generation else {
        return (state, [])
    }

    switch outcome {
    case .success:
        // 成功 → 失败债一笔勾销（`.runtimeUp` 不带 streak）。
        // 否则一次偶然成功之后的下一次失败会直接撞上熔断阈值。
        return (
            .runtimeUp(generation: current, baseline: false),
            [.notify(.reconcileSucceeded(generation: current))]
        )

    case .failure(.permanent):
        // 重试一万次也没用（容器不存在：白名单 ID 拼错、或者容器被 container delete 删了）。
        // **不重试、不退避、不计入熔断**——它不是 crashloop 的证据，它是配置错误。
        // 把两者混为一谈，用户会去查一个根本没崩的容器为什么崩。
        //
        // 运行时本身是好的，所以状态回到 `.runtimeUp`：supervisor 对这一代已经
        // 做完了它能做的事，剩下的要人来改白名单。
        return (
            .runtimeUp(generation: current, baseline: false),
            [.notify(.reconcileAbandoned(generation: current))]
        )

    case .failure(let kind):
        return retryable(
            kind: kind,
            generation: current,
            failures: failures,
            now: now,
            config: config,
            backoff: backoff
        )
    }
}

/// 可重试的失败：退避重试，**但只有 `.transient` 会把熔断计数往前推**。
///
/// ## 这个分岔是 Day 4 唯一真正要紧的东西
///
/// 熔断阈值「10 分钟内 5 次」配上「1→2→4→8→16 秒」的退避，**五次失败只花 31 秒**。
/// 而 R13 的核心场景（Mac 重启后外置盘/网络卷还没挂上）动辄要几分钟才就绪。
///
/// 若 `.environmentNotReady` 也计入熔断，supervisor 会在 **31 秒后熔断放弃**——
/// 正好死在它唯一该活着的那一刻，本 App 的全部价值当场归零。
///
/// 所以它照常退避重试（退避封顶 5 分钟，一直试下去的成本极低），
/// 但**永远不推进熔断计数**。熔断只留给真正的 crashloop。
private func retryable(
    kind: FailureKind,
    generation: RuntimeGeneration,
    failures: FailureStreak?,
    now: Date,
    config: SupervisorConfig,
    backoff: any BackoffPolicy
) -> (SupervisorState, [SupervisorEffect]) {
    // 两个计数一起往前走，但各数各的：
    // `attempts` 数所有失败（退避看它），`breakerFailures` 只记 .transient 的时刻（熔断看它）。
    let streak = (failures ?? .none).recording(
        kind,
        at: now,
        window: config.circuitBreakerWindow,
        threshold: config.circuitBreakerThreshold
    )

    // ★ 熔断：停止一切自动重试，等人来按。
    // 判据是 breakerCount 而不是 attempts —— `.environmentNotReady` 攒得再多也到不了这里，
    // 这正是 R13 的核心场景（外置盘还没挂上）不会在 31 秒后被判死的原因。
    if streak.breakerCount >= config.circuitBreakerThreshold {
        return (
            .circuitOpen(generation: generation, since: now),
            // **刻意不吐 scheduleTick**：再安排一次自动重试，熔断就成了摆设。
            [.notify(.circuitOpened(generation: generation, failures: streak.breakerCount))]
        )
    }

    // 退避重试。档位看 attempts —— 环境没就绪也要涨档，
    // 否则外置盘不挂上就会以 1 秒的间隔重试一整天。
    let retryAt = now.addingTimeInterval(backoff.delay(forAttempt: streak.attempts))

    return (
        .cooldown(generation: generation, until: retryAt, failures: streak),
        [
            .notify(.reconcileFailed(
                generation: generation,
                kind: kind,
                attempt: streak.attempts,
                retryAt: retryAt
            )),
            .scheduleTick(at: retryAt),
        ]
    )
}

// MARK: - tick

/// 定时器到点了。**只有 `.cooldown` 关心它。**
///
/// `.circuitOpen` 明确**不**响应 tick——那正是熔断的全部意义：停止一切自动重试。
private func tick(_ state: SupervisorState, now: Date) -> (SupervisorState, [SupervisorEffect]) {
    guard case .cooldown(let generation, let until, let failures) = state else {
        return (state, [])
    }

    // 到点或已过点都算到（不是严格大于）：tick 可能因为线程调度晚到几毫秒，
    // 用严格大于会让它白白多睡一整轮。
    guard now >= until else {
        return (state, [])
    }

    // ★ 失败债必须带进新一轮。丢了它，下一次失败又从第 1 次算起——
    // 退避永远停在第一档，熔断永远等不到阈值。
    return (
        .reconciling(generation: generation, failures: failures),
        [.startReconcile(generation: generation)]
    )
}

// MARK: - userForcedReconcile

/// 用户按了「立即启动受管容器」。**手动兜底必须存在**——
/// 任何自动状态机都有它没想到的局面，那时用户需要一个不讲道理、直接生效的出口。
private func userForcedReconcile(
    _ state: SupervisorState
) -> (SupervisorState, [SupervisorEffect]) {
    switch state {
    case .unknown, .runtimeDown:
        // 没有运行时可拉。**必须明说没做**——静默吞掉的话，用户会以为按钮坏了，
        // 然后去点第二次、第三次。
        (state, [.notify(.forcedReconcileUnavailable)])

    case .reconciling:
        // 已经在拉了。再下达一次只会得到两个并发的 reconcile。
        (state, [])

    case .runtimeUp(let generation, _),
         .cooldown(let generation, _, _),
         .circuitOpen(let generation, _):
        // cooldown 时按下 = 跳过等待立刻重试。
        // ★ circuitOpen 时按下 = **熔断的唯一出口**（PLAN：绝不静默无限重试，要求手动 reset）。
        //
        // **失败债一笔勾销**：这是用户的显式指令，不是自动重试。他很可能刚刚修好了根因
        // （插上外置盘、改对了白名单 ID、修好了容器）——让他继续背着旧的退避债、
        // 甚至一按就立刻撞回熔断，是在惩罚他做了正确的事。
        (freshReconcile(generation), [.startReconcile(generation: generation)])
    }
}
