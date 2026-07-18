import Testing

@testable import ContainerCore

/// **supervisor 的手。** 大脑（reducer）决定「该拉了」，这里真的去拉。
///
/// 它唯一有判断力的地方是**失败聚合**：一轮要拉多个容器，可能有的成、有的因为外置盘
/// 没挂上而失败、有的在 crashloop——但 reducer 只接受**一个** outcome。
/// 聚合选错，Day 4 的熔断要么变成摆设，要么在最不该开的时候开。
@Suite("ReconcileEngine")
struct ReconcileEngineTests {

    private let g = RuntimeGeneration(pid: 1, startTime: 1)

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    private func container(_ raw: String, _ state: ContainerState = .stopped) -> Container {
        Container(id: id(raw), image: ImageRef("busybox:1")!, state: state, environment: [])
    }

    private func whitelist(_ raws: [String]) -> FixedWhitelist {
        FixedWhitelist(list: raws.map { WhitelistEntry(id: id($0)) })
    }

    // MARK: - 正常路径

    @Test("拉起白名单里的每一个容器")
    func startsWhitelisted() async {
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b"), container("c")])
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a", "b"]))

        #expect(await engine.reconcile(generation: g) == .success)
        // ★ 断言的是**副作用**，不是最终状态：容器最后在跑，可能是我们拉的，
        // 也可能它本来就在跑。只有调用流水能区分这两者。
        #expect(await client.calls == [.start(id("a")), .start(id("b"))])
    }

    @Test("enabled = false 的条目不拉（用户正在调试它）")
    func skipsDisabled() async {
        let client = FakeContainerRuntimeClient(containers: [container("a"), container("b")])
        let engine = WhitelistReconcileEngine(
            client: client,
            whitelist: FixedWhitelist(list: [
                WhitelistEntry(id: id("a"), enabled: false),
                WhitelistEntry(id: id("b"), enabled: true),
            ])
        )

        #expect(await engine.reconcile(generation: g) == .success)
        #expect(await client.calls == [.start(id("b"))])
    }

    /// 白名单为空 = **没活干**，不是失败。
    ///
    /// 判成失败的话，一个还没配过白名单的新用户会看到 supervisor 不停退避、报错、
    /// 最后熔断——为了「什么都不用做」这件事。
    @Test("白名单为空 → success（没活干不算失败）")
    func emptyWhitelistSucceeds() async {
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        let engine = WhitelistReconcileEngine(client: client, whitelist: FixedWhitelist(list: []))

        #expect(await engine.reconcile(generation: g) == .success)
        #expect(await client.calls.isEmpty)
    }

    /// 已经在跑的容器：`ContainerRuntimeClient` 保证 start 幂等（静默成功）。
    /// 所以 engine **不需要先 list 一遍再挑**——那只是多一次 XPC 往返和一个竞态窗口
    /// （list 完到 start 之间容器状态可能又变了）。
    @Test("容器已在运行 → start 幂等，仍算成功")
    func alreadyRunningIsIdempotent() async {
        let client = FakeContainerRuntimeClient(containers: [container("a", .running)])
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a"]))

        #expect(await engine.reconcile(generation: g) == .success)
    }

    // MARK: - 失败分类（映射由 FailureClassification 负责，这里验它真的被用上了）

    @Test("mount 源没就绪 → environmentNotReady（退避重试，不熔断）")
    func mountFailureIsEnvironmental() async {
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        await client.inject(.mountSourceUnavailable(path: "/Volumes/data"), for: .start)
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a"]))

        #expect(await engine.reconcile(generation: g) == .failure(.environmentNotReady))
    }

    @Test("容器不存在 → permanent（白名单 ID 拼错了，重试没用）")
    func missingContainerIsPermanent() async {
        let client = FakeContainerRuntimeClient(containers: [])
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["ghost"]))

        #expect(await engine.reconcile(generation: g) == .failure(.permanent))
    }

    @Test("操作失败 → transient（计入熔断）")
    func operationFailureIsTransient() async {
        let client = FakeContainerRuntimeClient(containers: [container("a")])
        await client.inject(.operationFailed(reason: "exit 1"), for: .start)
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a"]))

        #expect(await engine.reconcile(generation: g) == .failure(.transient))
    }

    // MARK: - ★ 聚合优先级：transient > environmentNotReady > permanent

    /// **这条是拍板过的取舍。**
    ///
    /// A 因外置盘没挂上失败（environmentNotReady），B 在 crashloop（transient）。
    /// 若报 environmentNotReady，熔断就被**永久屏蔽**——只要有一块盘没插上，
    /// B 就能无限打铁，把 CPU 和日志一起烧光。熔断当场变成摆设。
    ///
    /// 所以 transient 优先。**残余风险（已知、已接受）**：熔断开了之后，
    /// 本该继续等下去的 A 也一起停了。出口是菜单里的手动 "Start now"。
    @Test("环境失败 + crashloop 同时发生 → 报 transient（否则熔断永远开不了）")
    func transientWinsOverEnvironmental() async {
        let client = SelectiveFailureClient(failures: [
            id("a"): .mountSourceUnavailable(path: "/Volumes/data"),
            id("b"): .operationFailed(reason: "exit 1"),
        ])
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a", "b"]))

        #expect(await engine.reconcile(generation: g) == .failure(.transient))
    }

    /// permanent 的优先级**最低**：一个 ID 拼错的条目，不该让另一个「正在等外置盘」的容器
    /// 陪着一起被放弃。前者每轮白试一次（无害），后者必须继续退避重试。
    @Test("环境失败 + 容器不存在 → 报 environmentNotReady（还得继续等盘）")
    func environmentalWinsOverPermanent() async {
        let client = SelectiveFailureClient(failures: [
            id("a"): .mountSourceUnavailable(path: "/Volumes/data"),
            id("ghost"): .containerNotFound(id("ghost")),
        ])
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a", "ghost"]))

        #expect(await engine.reconcile(generation: g) == .failure(.environmentNotReady))
    }

    /// 一个失败**不能中断**其余容器的启动：B 起不来，C 还是该起来。
    /// 早退（第一个失败就 return）会让白名单的后半截在每次环境抖动时全部失守。
    @Test("一个容器失败，其余仍会被尝试")
    func failureDoesNotAbortTheRest() async {
        let client = SelectiveFailureClient(failures: [id("b"): .operationFailed(reason: "exit 1")])
        let engine = WhitelistReconcileEngine(client: client, whitelist: whitelist(["a", "b", "c"]))

        #expect(await engine.reconcile(generation: g) == .failure(.transient))
        #expect(await client.started == [id("a"), id("b"), id("c")])
    }
}

// MARK: - 替身

/// 固定白名单。
struct FixedWhitelist: WhitelistProvider {

    let list: [WhitelistEntry]

    func entries() async -> [WhitelistEntry] { list }
}

/// **按容器**注入失败的客户端。
///
/// `FakeContainerRuntimeClient` 只能按**操作**注入（所有 start 一起失败），
/// 表达不出「A 因缺盘失败、B 在 crashloop」——而聚合优先级的全部争议恰恰在那儿。
actor SelectiveFailureClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private let failures: [ContainerID: RuntimeError]

    /// 按调用顺序记录。engine「不早退」这条断言只能靠它验。
    private(set) var started: [ContainerID] = []

    init(failures: [ContainerID: RuntimeError]) {
        self.failures = failures
    }

    func list() throws(RuntimeError) -> [Container] { [] }

    func start(id: ContainerID) throws(RuntimeError) {
        started.append(id)
        if let error = failures[id] { throw error }
    }

    func stop(id: ContainerID) throws(RuntimeError) {}

    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample {
        ContainerStatsSample()
    }
}
