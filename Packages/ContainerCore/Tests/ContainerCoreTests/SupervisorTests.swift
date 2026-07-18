import Foundation
import Testing

@testable import ContainerCore

/// **本 App 存在的理由，第一次被端到端地证明。**
///
/// Day 3–4 证明的是「大脑会做对决定」（reducer 单测）。这里证明的是另一件事：
/// **那些决定真的变成了对容器的 start 调用。** 两者之间隔着一整层 Effect 执行，
/// 而 bug 最爱住在那种夹层里。
///
/// 全程零真实等待（`ManualClock`），所以不会有间歇性红。
@Suite("Supervisor")
struct SupervisorTests {

    private let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)
    private let g2 = RuntimeGeneration(pid: 200, startTime: 2_000)

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    private func container(_ raw: String) -> Container {
        Container(id: id(raw), image: ImageRef("busybox:1")!, state: .stopped, environment: [])
    }

    /// 白名单里两个容器；客户端是 Fake（记调用流水）；时钟是手动的。
    private func makeSupervisor(
        prober: FakeRuntimeProber,
        client: FakeContainerRuntimeClient,
        clock: ManualClock,
        config: SupervisorConfig = .default,
        notices: NoticeRecorder = NoticeRecorder()
    ) -> Supervisor {
        Supervisor(
            prober: prober,
            engine: WhitelistReconcileEngine(
                client: client,
                whitelist: FixedWhitelist(list: [
                    WhitelistEntry(id: id("a")),
                    WhitelistEntry(id: id("b")),
                ])
            ),
            config: config,
            backoff: FixedBackoff(10),
            clock: clock,
            observe: { snapshot in notices.record(snapshot) }
        )
    }

    // MARK: - ★ 核心场景：运行时回来了，容器被自动拉起

    /// **这一条通过，整个项目就成立了**（PLAN「验证方式」）。
    ///
    /// apple/container 没有 restart policy：运行时回来，容器不会自己回来。
    /// 这里就是那个洞被补上的瞬间。
    @Test("运行时 down → up：白名单容器被自动拉起")
    func runtimeComesBackAndContainersAreStarted() async {
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = makeSupervisor(prober: prober, client: client, clock: ManualClock())

        await supervisor.step()
        #expect(await supervisor.state == .runtimeDown)
        #expect(await client.calls.isEmpty)   // 运行时不在时不该乱试

        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()

        #expect(await supervisor.state == .runtimeUp(generation: g1, baseline: false))
        #expect(await client.calls == [.start(id("a")), .start(id("b"))])
    }

    /// **冷启动不代劳**（PLAN 已拍板）：容器停着可能是用户 5 分钟前手动停下来调试的。
    @Test("冷启动时运行时已在跑 → baseline，不拉起")
    func coldStartDoesNotReconcile() async {
        let prober = FakeRuntimeProber(.running(g1))
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = makeSupervisor(prober: prober, client: client, clock: ManualClock())

        await supervisor.step()
        await supervisor.awaitReconcile()

        #expect(await supervisor.state == .runtimeUp(generation: g1, baseline: true))
        #expect(await client.calls.isEmpty)
    }

    /// ★ **D3 的整个理由。**
    ///
    /// 运行时快速重启（`container system restart`，<2s）会在两次探测之间跑完——
    /// 两次探测都看到 running，纯边沿检测**什么都看不见**，容器却已经全没了。
    /// 令牌变了 = 中间必然死过一次。
    @Test("两次探测都是 running，但令牌变了 → 仍然 reconcile（漏检 down 也救得回来）")
    func generationChangeTriggersReconcileWithoutSeeingDown() async {
        let prober = FakeRuntimeProber(.running(g1))
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = makeSupervisor(
            prober: prober,
            client: client,
            clock: ManualClock(),
            config: SupervisorConfig(reconcileOnLaunch: true)   // 让冷启动那一轮先把 g1 处理掉
        )

        await supervisor.step()
        await supervisor.awaitReconcile()
        #expect(await client.calls.count == 2)

        // 运行时在两次探测之间死了又活了——我们**从没看见过 down**。
        await prober.set(.running(g2))
        await supervisor.step()
        await supervisor.awaitReconcile()

        #expect(await supervisor.state == .runtimeUp(generation: g2, baseline: false))
        #expect(await client.calls.count == 4)   // 又拉了一遍
    }

    // MARK: - 失败与退避

    /// 失败 → cooldown → tick 到点 → **真的重试了**。
    ///
    /// reducer 单测只能证明它「发出了 scheduleTick」；这里证明那个 tick 真的被执行了、
    /// 真的把 reconcile 重新跑了一遍。中间隔着一条定时器 task——bug 最爱住在那儿。
    @Test("reconcile 失败 → cooldown → 退避到期 → 自动重试")
    func failureBacksOffThenRetries() async {
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        await client.inject(.operationFailed(reason: "boom"), for: .start)
        let clock = ManualClock()
        let supervisor = makeSupervisor(prober: prober, client: client, clock: clock)

        // 先看到 down，才会走「运行时回来了」那条边沿。
        await supervisor.step()
        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()

        let attempted = await client.calls.count
        #expect(attempted == 2)

        guard case .cooldown(let generation, _, let failures) = await supervisor.state else {
            Issue.record("失败之后应该进 cooldown")
            return
        }
        #expect(generation == g1)
        #expect(failures.attempts == 1)

        // 退避到期（FixedBackoff(10) → 10 秒后）。
        await clock.advance(by: 10)
        await supervisor.awaitTick()
        await supervisor.awaitReconcile()

        // ★ 真的重试了：又对两个容器下达了 start。
        #expect(await client.calls.count == attempted + 2)
    }

    /// **熔断的唯一出口是人。** 而且它必须把失败债清零——
    /// 用户很可能刚刚修好了根因（插上外置盘、改对了 ID），
    /// 让他一按就立刻撞回熔断，是在惩罚他做了正确的事。
    @Test("熔断之后，用户手动 Start now 能把它救回来")
    func userCanResetTheCircuitBreaker() async {
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        await client.inject(.operationFailed(reason: "crashloop"), for: .start)
        let clock = ManualClock()
        let supervisor = makeSupervisor(
            prober: prober,
            client: client,
            clock: clock,
            config: SupervisorConfig(circuitBreakerThreshold: 2)
        )

        await supervisor.step()
        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()   // 第 1 次失败 → cooldown

        await clock.advance(by: 10)
        await supervisor.awaitTick()
        await supervisor.awaitReconcile()   // 第 2 次失败 → 熔断

        guard case .circuitOpen = await supervisor.state else {
            Issue.record("两次 transient 失败后应该熔断")
            return
        }

        // 熔断中：**不再有任何自动重试**。推时间也不会有 tick 把它叫醒。
        let frozen = await client.calls.count
        await clock.advance(by: 3_600)
        #expect(await client.calls.count == frozen)

        // 用户修好了根因，按下 "Start now"。
        await client.inject(nil, for: .start)
        await supervisor.forceReconcile()
        await supervisor.awaitReconcile()

        #expect(await supervisor.state == .runtimeUp(generation: g1, baseline: false))
        #expect(await client.calls.count == frozen + 2)
    }

    /// ★ **R13：外置盘还没挂上，绝不能熔断。**
    ///
    /// 这条是 CLAUDE.md D4 那条硬约束在 actor 层的证明：
    /// 环境失败攒到天荒地老也不会熔断，它会一直退避重试——因为等下去就一定会成功。
    @Test("环境未就绪（外置盘没挂上）反复失败，也永远不熔断")
    func environmentNotReadyNeverTripsTheBreaker() async {
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        await client.inject(.mountSourceUnavailable(path: "/Volumes/data"), for: .start)
        let clock = ManualClock()
        let supervisor = makeSupervisor(
            prober: prober,
            client: client,
            clock: clock,
            config: SupervisorConfig(circuitBreakerThreshold: 2)   // 极易熔断的阈值
        )

        await supervisor.step()
        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()

        // 再失败 10 次——阈值是 2，若环境失败计入熔断，早就断了。
        for _ in 0..<10 {
            await clock.advance(by: 10)
            await supervisor.awaitTick()
            await supervisor.awaitReconcile()
        }

        guard case .cooldown(_, _, let failures) = await supervisor.state else {
            Issue.record("环境失败应该一直退避重试，不该熔断")
            return
        }
        #expect(failures.attempts == 11)     // 退避档位一直在涨
        #expect(failures.breakerCount == 0)  // ★ 熔断计数一直是 0

        // 盘挂上了 → 下一次重试就成功。
        await client.inject(nil, for: .start)
        await clock.advance(by: 10)
        await supervisor.awaitTick()
        await supervisor.awaitReconcile()

        #expect(await supervisor.state == .runtimeUp(generation: g1, baseline: false))
    }

    // MARK: - 通知

    @Test("拉起成功要通知用户（supervisor 不吭声时，看起来和没干活一模一样）")
    func noticesAreEmitted() async {
        let notices = NoticeRecorder()
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = makeSupervisor(
            prober: prober,
            client: client,
            clock: ManualClock(),
            notices: notices
        )

        await supervisor.step()
        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()

        #expect(notices.all == [.reconcileSucceeded(generation: g1)])
    }

    // MARK: - 生命周期

    /// 重复 `start()` 起两条探测循环的话，每次换代都会触发两次 reconcile。
    @Test("重复 start 不会起两条探测循环")
    func startIsIdempotent() async {
        let prober = FakeRuntimeProber(.running(g1))
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = makeSupervisor(
            prober: prober,
            client: client,
            clock: ManualClock(),
            config: SupervisorConfig(reconcileOnLaunch: true)
        )

        await supervisor.start()
        await supervisor.start()
        await supervisor.awaitReconcile()
        await supervisor.stop()

        // 两条循环的话这里会是 4。
        #expect(await client.calls.count == 2)
    }

    /// ★ **start 途中被 stop（codex review 抓到的竞态）。**
    ///
    /// `start()` 挂在首次 `await step()` 上时，`stop()` 插进来——它那一刻看到的 `probeTask`
    /// 还是 `nil`，**什么都取消不掉**。若 `start()` 恢复后不复查，它会把轮询循环照常装上去：
    /// supervisor 在被明确叫停之后继续探测下去（常驻 App 里就是一条永不退出的循环）。
    ///
    /// 这条测试用一个可闸住的 prober 精确地卡在那个窗口里，不靠 sleep 撞运气。
    @Test("start 途中被 stop → 不装轮询循环，且一个容器都不许碰")
    func stopDuringStartWins() async {
        let prober = GatedProber(.running(g1))
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let supervisor = Supervisor(
            prober: prober,
            engine: WhitelistReconcileEngine(
                client: client,
                whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("a"))])
            ),
            // 冷启动就 reconcile —— 把「stop 之后还会不会去起容器」这条路径**打开**。
            // 不打开它，这条测试就只能验到「循环没装上」，验不到真正要命的那一半。
            config: SupervisorConfig(reconcileOnLaunch: true),
            backoff: FixedBackoff(10),
            clock: ManualClock(),
            probeInterval: 1
        )

        let starting = Task { await supervisor.start() }

        await prober.waitUntilProbing()   // start() 此刻正卡在首次 probe 里
        await supervisor.stop()           // 这时 probeTask 还是 nil —— 取消不到任何东西
        await prober.release()
        await starting.value
        await supervisor.awaitReconcile()

        // **断言不变式本身，不断言它的副作用。**
        // 「推时钟然后数 probe 次数」是在跟调度器赛跑：那条循环 Task 还没被调度到，
        // 断言就已经通过了——第一版就是这么写的，突变测试（拿掉修复）照样全绿。
        #expect(await supervisor.isProbing == false)

        // ★ 真正要命的那一半：**被叫停之后，绝不许再去起容器。**
        // App 正在退出时把容器拉起来，是实打实的错。
        #expect(await client.calls.isEmpty)
        #expect(await supervisor.state == .unknown)
    }

    /// ★ **在途 reconcile 的结果，不许在 stop 之后落地**（codex review 第三轮抓到的）。
    ///
    /// reconcile 跑到一半用户退出 App。它失败了——结果回来时若被采纳，状态会被推成
    /// `.cooldown` 并**排一个新的 tick**：App 都退出了，后台还在等着重试拉容器。
    ///
    /// 一处处加 `guard !Task.isCancelled` 挡不住它：那个 guard 和 `handle` 之间
    /// 还隔着一个 actor 跳转——**`await` 本身就是窗口**。挡住它的是 `deliver` 里的 epoch 校验。
    @Test("reconcile 结果在 stop 之后回来 → 丢弃，不进 cooldown、不排新 tick")
    func lateReconcileResultAfterStopIsDiscarded() async {
        let prober = FakeRuntimeProber(.down)
        let engine = GatedEngine(outcome: .failure(.transient))
        let supervisor = Supervisor(
            prober: prober,
            engine: engine,
            backoff: FixedBackoff(10),
            clock: ManualClock()
        )

        await supervisor.step()             // → runtimeDown
        await prober.set(.running(g1))
        await supervisor.step()             // → reconciling（engine 被闸在里面）

        await engine.waitUntilReconciling()
        await supervisor.stop()             // 用户在这时退出了 App
        await engine.release()              // reconcile 这才失败返回

        // **不能用 `awaitReconcile()` 等**：`stop()` 已经把 `reconcileTask` 置 nil 了，
        // 那句话什么都等不到——于是断言会在那条孤儿 Task 真正回投**之前**跑完，
        // 假绿（第一版就是这么写的，突变测试照样通过）。
        // 这里要等的是那条 Task 真的走到 `deliver` 并被 epoch 拦下。
        await engine.settle()

        // 若这条迟到的失败被采纳，状态会变成 `.cooldown` 并排一个 tick——
        // App 都退出了，后台还等着重试拉容器。
        #expect(await supervisor.state == .reconciling(generation: g1, failures: nil))
    }

    /// `stop()` 必须能把**正在睡的** tick task 叫停。
    /// 叫不停 = 常驻进程里每次退避都泄漏一条 task。
    @Test("stop 能中止正在睡的 tick（不会挂死）")
    func stopCancelsSleepingTick() async {
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        await client.inject(.operationFailed(reason: "boom"), for: .start)
        let supervisor = makeSupervisor(prober: prober, client: client, clock: ManualClock())

        await supervisor.step()
        await prober.set(.running(g1))
        await supervisor.step()
        await supervisor.awaitReconcile()   // → cooldown，tick 正在睡

        await supervisor.stop()             // 若 ManualClock 不响应取消，这里会挂死
    }
}

// MARK: - 观测通道

@Suite("Supervisor 观测通道")
struct SupervisorObservationTests {

    private let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    /// 快照的 `sequence` 必须**严格单调递增**——`SupervisorStatusStore` 拿它当
    /// 「这份是不是比我手上那份新」的唯一判据。它若不单调，那道防乱序的闸门形同虚设。
    ///
    /// 而且每份快照的 `state` 必须**等于那一轮 handle 之后的真实状态**：
    /// 快照是 UI 唯一看得见的东西，它撒一次谎，界面就撒一辈子谎。
    @Test("每处理一个事件投一份快照，sequence 严格递增且 state 与 supervisor 一致")
    func snapshotsAreSequencedAndTruthful() async {
        let recorder = NoticeRecorder()
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [
            Container(id: id("a"), image: ImageRef("busybox:1")!, state: .stopped, environment: [])
        ])
        let supervisor = Supervisor(
            prober: prober,
            engine: WhitelistReconcileEngine(
                client: client,
                whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("a"))])
            ),
            backoff: FixedBackoff(10),
            clock: ManualClock(),
            observe: { recorder.record($0) }
        )

        await supervisor.step()             // → runtimeDown
        await prober.set(.running(g1))
        await supervisor.step()             // → reconciling
        await supervisor.awaitReconcile()   // → runtimeUp（reconcileFinished 回投）

        let sequences = recorder.sequences
        #expect(sequences == [1, 2, 3])

        // 最后一份快照说的话，和 supervisor 自己的状态是同一件事。
        #expect(recorder.states.last == .runtimeUp(generation: g1, baseline: false))
        #expect(await supervisor.state == .runtimeUp(generation: g1, baseline: false))
        #expect(recorder.all == [.reconcileSucceeded(generation: g1)])
    }
}

// MARK: - 替身

/// 收集 supervisor 投出的快照（以及其中的通知）。
///
/// `observe` 是 `@Sendable` 闭包，从 actor 里**同步**调用——所以线程安全得自己保证。
/// 用锁而不是 actor：actor 的话 `observe` 就得 `await`，而 `handle` 是**刻意全程同步**的
/// （那是它没有重入窗口的全部依据）。
final class NoticeRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var snapshots: [SupervisorSnapshot] = []

    func record(_ snapshot: SupervisorSnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }

    var all: [SupervisorNotice] {
        lock.withLock { snapshots.flatMap(\.notices) }
    }

    var sequences: [Int] {
        lock.withLock { snapshots.map(\.sequence) }
    }

    var states: [SupervisorState] {
        lock.withLock { snapshots.map(\.state) }
    }
}
