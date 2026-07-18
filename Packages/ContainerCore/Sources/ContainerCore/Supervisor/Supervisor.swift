import Foundation

/// **把大脑接到手脚上。**
///
/// Day 3–4 造出的 `reduce` 能正确决定「该 reconcile 了 / 该退避 / 该熔断」，但它是纯函数：
/// 它只**描述**副作用（返回 `[SupervisorEffect]`），一个都不执行。这台 actor 就是执行者。
///
/// ## 它刻意什么判断都不做
///
/// 下面没有一个 `if` 在决定「要不要 reconcile」——那种判断全在 reducer 里，
/// 而 reducer 是纯函数、100% 覆盖。这里只做三件机械的事：
/// **把事件喂给 reducer、把新状态存下来、把 Effect 一条条执行掉。**
///
/// 每往这里塞一个判断，就有一个判断脱离了那套 100% 覆盖的测试。
///
/// ## `handle` 内部不 `await`，所以 actor 没有重入窗口
///
/// `@MainActor` 挡不住重入（`ContainerListStore` 那条「旧刷新覆盖新刷新」就是这么来的），
/// actor 同样挡不住——只要方法体里有 `await`，别的调用就能插进来。
/// 这里的做法是：`handle` 全程同步（reduce 是纯函数，Effect 全部 fire-and-forget），
/// 于是「读状态 → 算新状态 → 写状态」这一段**不可能被打断**。
///
/// 异步结果（reconcile 完成、tick 到点）一律作为**新事件**重新投进来，
/// 由 reducer 用 generation 令牌做 stale 判定——而不是直接写状态。
public actor Supervisor {

    private let prober: any RuntimeProber
    private let engine: any ReconcileEngine
    private let config: SupervisorConfig
    private let backoff: any BackoffPolicy
    private let clock: any SupervisorClock
    private let probeInterval: TimeInterval

    /// **决策的观测出口**（Day 8）。默认 `NullSupervisorLog`，`AppModel` 注 `OSLogSupervisorLog`。
    ///
    /// 它的方法全是同步、fire-and-forget（见 `SupervisorLog` 的实现纪律）——所以在 `handle`
    /// 里调它**不引入任何挂起点**，「handle 全程同步、无重入窗口」这条不变式原样成立。
    private let log: any SupervisorLog

    /// **UI 与外界看见 supervisor 的唯一窗口。**
    ///
    /// 刻意不是「状态一个回调 + 通知一个回调」：那样同一次 `handle` 的产物会被拆成两半，
    /// 各自跨一次 actor → MainActor 的跳转，而跳转不保证顺序——于是界面上能出现
    /// 「状态是 runtimeUp、底下挂着一行『熔断了』」这种各自都对、凑一起是假的东西。
    /// 一次 handle = 一份快照 = 一次投递（见 `SupervisorSnapshot`）。
    private let observe: @Sendable (SupervisorSnapshot) -> Void

    /// 快照序号。**只在这个 actor 里递增**，所以是全序的——
    /// 消费者（`SupervisorStatusStore`）靠它把迟到的旧快照丢掉。
    private var sequence = 0

    /// 当前状态。UI 读它来决定菜单栏图标（正在拉起 / 熔断了 / 一切正常）。
    public private(set) var state: SupervisorState = .unknown

    /// **不能用 `probeTask == nil` 当幂等判据。**
    ///
    /// `start()` 里有 `await`（首次探测），而 actor 在 `await` 处是**可重入**的——
    /// 两次并发 start 会双双穿过 `guard probeTask == nil`（那时它还没被赋值），
    /// 于是起两条探测循环，此后每次换代都触发两次 reconcile。
    ///
    /// 这个标志在第一个 `await` **之前**同步置位，所以第二次调用一定看得见它。
    /// （`ContainerListStore` 的「旧刷新覆盖新刷新」是同一个坑：`@MainActor` 也挡不住重入。）
    private var isRunning = false

    /// **叫停令牌**（codex review 抓到的，第二轮才补全）。每次 `stop()` 递增。
    ///
    /// `guard isRunning` 只拦住了「装轮询循环」，拦不住**已经在途的那次 `step()`**：
    /// `stop()` 之后 probe 恢复 → `handle` 照样跑 → 照样发起 reconcile → **真的去起容器**。
    /// App 正在退出时把容器拉起来，是实打实的错。
    ///
    /// 这跟 reducer 用 generation 令牌拦 stale 结果、`ContainerListStore` 用 Task 令牌
    /// 作废旧刷新，是同一条纪律：**跨过 `await` 之后，你得证明自己还活在同一个世界里。**
    /// 这个仓库里已经栽在这上面三次了。
    private var epoch = 0

    private var probeTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    public init(
        prober: any RuntimeProber,
        engine: any ReconcileEngine,
        config: SupervisorConfig = .default,
        backoff: any BackoffPolicy = ExponentialBackoff(),
        clock: any SupervisorClock = SystemSupervisorClock(),
        probeInterval: TimeInterval = 2,
        log: any SupervisorLog = NullSupervisorLog(),
        observe: @escaping @Sendable (SupervisorSnapshot) -> Void = { _ in }
    ) {
        self.prober = prober
        self.engine = engine
        self.config = config
        self.backoff = backoff
        self.clock = clock
        self.probeInterval = probeInterval
        self.log = log
        self.observe = observe
    }

    // MARK: - 生命周期

    /// 开始探测。**幂等**（见 `isRunning`：两条探测循环会让每次换代都触发两次 reconcile）。
    ///
    /// **第一次探测在这里同步做掉**，然后才起循环。理由不是为了测试好写：
    /// app 冷启动时用户要立刻看到运行时状态，而不是等一个探测周期
    /// （更要命的是「Mac 重启后 apiserver 还没起来」那一刻——那正是 supervisor 该盯紧的时候）。
    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        await step()

        // ★ **`await` 之后世界可能已经变了**（codex review 抓到的）。
        //
        // `stop()` 完全可能在上面那个 `await` 期间插进来——而它那时看到的 `probeTask`
        // 还是 `nil`，于是**什么都没取消掉**。若这里不复查，`start()` 恢复后会把轮询循环
        // 照常装上去：supervisor 在被明确叫停之后，继续探测下去。
        //
        // 这是 `isRunning` 那条注释里说的同一种重入，我上面只堵了它的一半：
        // 挡住了「两次 start」，没挡住「start 途中被 stop」。
        // **每个 `await` 都是一道门，进门前的判断出门后未必还成立。**
        guard isRunning else { return }

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 先睡再探：第一轮已经在上面探过了。
                await self.sleepOneInterval()
                guard !Task.isCancelled else { return }
                await self.step()
            }
        }
    }

    /// 停止一切。菜单栏 App 是常驻进程——睡着的 task 不 cancel 就会一直累积。
    ///
    /// 递增 `epoch`：在途的 `step()` / `forceReconcile()` 恢复后会发现世界变了，闭嘴退出。
    /// 光 cancel 那三个 task 是不够的——**它们那时可能还不存在**。
    public func stop() {
        epoch += 1
        isRunning = false
        probeTask?.cancel()
        reconcileTask?.cancel()
        tickTask?.cancel()
        probeTask = nil
        reconcileTask = nil
        tickTask = nil
    }

    /// 探一次并处理。**public 是为了让测试能一步一步驱动**（不必等真实时间流逝）——
    /// 手动调它和让 `start()` 的循环调它，走的是同一条代码路径。
    ///
    /// 探测和读时钟都要 `await`，而 `stop()` 可以在这两个窗口里插进来。
    /// 恢复后**先验令牌再动手**：已经被叫停了就闭嘴退出，绝不能再去起容器。
    public func step() async {
        let epoch = self.epoch

        let result = await prober.probe()
        let now = await clock.now()

        deliver(.probed(result, at: now), epoch: epoch)
    }

    /// 用户按了「立即启动受管容器」。**手动兜底必须存在**（PLAN）：
    /// 任何自动状态机都有它没想到的局面，那时用户需要一个不讲道理、直接生效的出口。
    /// 它也是**熔断的唯一出口**。
    public func forceReconcile() async {
        let epoch = self.epoch
        let now = await clock.now()

        deliver(.userForcedReconcile(at: now), epoch: epoch)
    }

    // MARK: - 确定性等待点（测试驱动用）

    /// 等在途的 reconcile 跑完（连同它回投的 `reconcileFinished` 被处理完）。
    ///
    /// **它存在只是为了让测试不必靠 sleep 撞运气。** 生产上没有调用方：
    /// 那边根本不关心「reconcile 什么时候完」——完了自然会有事件进来。
    ///
    /// 不给这个钩子，测试就只能写成「睡 50 毫秒然后但愿它跑完了」——
    /// 那种测试在 CI 上必然间歇性红，然后被人加 `.disabled` 关掉。
    public func awaitReconcile() async {
        _ = await reconcileTask?.value
    }

    /// 等在途的 tick 触发（要先把 `ManualClock` 推过它的 deadline，否则会一直等下去）。
    public func awaitTick() async {
        _ = await tickTask?.value
    }

    /// 轮询循环还在不在。
    ///
    /// **测试要断言的是这个不变式本身，不是它的副作用。** 「stop 之后还会不会再探测」
    /// 若靠「推时钟然后数 probe 次数」去验，就变成了跟调度器赛跑——
    /// 那条 Task 还没被调度到，断言就已经通过了（假绿，实测撞到过）。
    /// `start()` 返回之后「循环装没装上」是个**确定的事实**，直接问它。
    public var isProbing: Bool { probeTask != nil }

    // MARK: - 事件泵

    /// **所有异步回投的唯一入口。** 验令牌 + 处理事件，两件事焊成一个原子操作。
    ///
    /// ## 为什么不能在调用方那边 `guard` 一下就完事
    ///
    /// 试过，不行——codex review 连着两轮抓的都是这个：
    ///
    /// ```swift
    /// guard !Task.isCancelled else { return }      // ← 这里还活着
    /// await self.handle(event)                     // ← 这个 await 是个新窗口，stop() 能插进来
    /// ```
    ///
    /// **`await` 本身就是窗口。** 在窗口外面检查，检查完了世界就可能变了。
    /// 补丁式地在每个回投点加 guard 是打地鼠：漏一个就是「App 退出后容器被拉起来」。
    ///
    /// 这个方法是**同步的、actor 隔离的**——一旦开始执行，`epoch` 校验和 `handle`
    /// 之间插不进任何东西。所有异步结果都必须从这一个门进来，于是「漏掉一个回投点」
    /// 这件事**写不出来**。
    ///
    /// （同一条纪律的第三次出现：reducer 用 generation 令牌拦 stale 结果、
    /// `ContainerListStore` 用 Task 令牌作废旧刷新。**跨过 await 就得重新证明自己还活着。**）
    private func deliver(_ event: SupervisorEvent, epoch: Int) {
        guard epoch == self.epoch else { return }

        handle(event)
    }

    /// **全程同步。** 见类型文档：这是「没有重入窗口」的全部依据。
    ///
    /// 快照在 Effect 执行**之后**投出去，且投的是这一轮的 `(state, notices)` 一整份——
    /// 于是 UI 永远看到一个自洽的横截面，而不是两个通道拼出来的幻觉。
    ///
    /// **没有变化的那些轮次不投。** 稳态下轮询每 2 秒喂一个 `probed(同一代 running)`，
    /// reducer 对它们一律不动作——状态没变、也没有通知。照投的话，一个常驻进程会每 2 秒
    /// 白白触发一次 MainActor 调度 + 一次 `@Observable` 写入（它的 setter 不做相等短路），
    /// 于是每个读 supervisor 状态的 view 每 2 秒重算一次，永远如此。
    private func handle(_ event: SupervisorEvent) {
        // 人工兜底 vs 自动边沿：两者都会走到 `.reconciling`，靠这条区分谁发起的（Day 8）。
        if case .userForcedReconcile = event { log.userForcedReconcile() }

        let (next, effects) = reduce(state, event, config: config, backoff: backoff)

        let old = state
        let changed = next != old

        // ★ 日志独立于快照投递：**该记的记，不管这一轮投不投快照**。
        // 用 `old` 记转移（`state` 还没被覆盖）；outcome 记的是事件本身，
        // 迟到 / 换代作废的结局也会记（带 generation 定位），最终状态仍只以 reducer 采纳的为准（P1-5）。
        if changed { log.transition(from: old, to: next) }
        if case .reconcileFinished(let outcome, let generation, _) = event {
            log.reconcileOutcome(outcome, generation: generation)
        }

        state = next
        // effect 派生的日志（reconcileStarted / notice）在 `perform` 里就地记——
        // perform 本就穷尽 switch 了一遍 effects，不必在这里再单独扫一遍。
        effects.forEach(perform)

        let notices = effects.compactMap(\.notice)

        guard changed || !notices.isEmpty else { return }

        sequence += 1
        observe(SupervisorSnapshot(state: next, notices: notices, sequence: sequence))
    }

    private func perform(_ effect: SupervisorEffect) {
        switch effect {
        case .startReconcile(let generation):
            log.reconcileStarted(generation: generation)
            startReconcile(for: generation)

        case .cancelReconcile:
            // **作废，不保证中止**（`SupervisorEffect` 的文档记了同一条）：
            // 底层没有取消语义，在途的 reconcile 可能照跑完。
            // 真正拦住它的是 reducer 的 stale 判定——迟到的结果带着旧令牌，不会被采纳。
            reconcileTask?.cancel()

        case .scheduleTick(let deadline):
            scheduleTick(at: deadline)

        case .notify(let notice):
            // **只记日志，不在这里投递给 UI**——UI 的那份通知跟着这一轮的快照一起走（见 `handle`）：
            // 单独投给 UI 的话，它和状态就成了两个通道、两次调度跳转、两种到达顺序。
            // 记日志是另一回事（日志是旁路 sink，不参与快照的自洽性）。
            log.notice(notice)
        }
    }

    private func startReconcile(for generation: RuntimeGeneration) {
        // 上一轮若还在跑，先作废。reducer 在换代路径上会显式发 `.cancelReconcile`，
        // 这里再收一次口：**任何时刻只允许一个 reconcile 在途**——
        // 否则两轮并发去 start 同一批容器，调用流水会变得没法解释。
        reconcileTask?.cancel()

        let epoch = self.epoch

        reconcileTask = Task { [engine, clock] in
            let outcome = await engine.reconcile(generation: generation)

            // **这里刻意没有 `guard !Task.isCancelled`。**
            //
            // 它看起来是个便宜的早退，实际是个陷阱：它和 `deliver` 之间还隔着一个
            // actor 跳转（**又一个窗口**），所以它挡不住 `stop()`——却会**掩盖**真正
            // 拦住它的那个机制（epoch），让守卫 epoch 的测试变成假绿（实测撞到过）。
            //
            // 两个机制、其中一个测不到，不如**一个机制、被测到**：
            // - `stop()` 之后的回投 → `deliver` 的 epoch 校验拦下；
            // - 旧世代的回投（换代作废）→ reducer 的 generation 令牌拦下（既有机制，已测）。
            //
            // 代价只是一次白跑的 actor 跳转。
            await self.deliver(
                .reconcileFinished(outcome, generation: generation, at: clock.now()),
                epoch: epoch
            )
        }
    }

    private func scheduleTick(at deadline: Date) {
        // 只允许一个 tick 在途：cooldown 被新的失败刷新时，旧 tick 必须作废——
        // 否则它到点时会把一个**更早的**重试硬塞进来，退避曲线当场失效。
        tickTask?.cancel()

        let epoch = self.epoch

        tickTask = Task { [clock] in
            await clock.sleep(until: deadline)

            // 同上，没有 `isCancelled` 早退。一个醒过来的 tick 若在 stop 之后被处理，
            // `.cooldown` 会被推成 `.reconciling`——**App 都退出了还去起容器**。
            // 拦住它的是 epoch；被换代作废的那个旧 tick 则由 reducer 拦
            // （它醒来时状态早已不是当初那个 `.cooldown` 了）。
            await self.deliver(.tick(now: clock.now()), epoch: epoch)
        }
    }

    private func sleepOneInterval() async {
        await clock.sleep(until: await clock.now().addingTimeInterval(probeInterval))
    }
}
