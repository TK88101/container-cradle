import Testing

@testable import ContainerCore

/// `FakeContainerRuntimeClient` 是**唯一**能在 CI / 单测里驱动 supervisor 的运行时。
/// 真运行时要 XPC、要真容器、要几十秒起停——那不是单测能承受的循环。
///
/// 所以 Fake 的行为必须与真运行时的**语义**对齐，尤其两条容易想当然的：
///
/// 1. **起停是幂等的**（官方 CLI 自己就短路：`if container.status == .running { return }`，
///    见 `Spikes/SPIKE-RESULT.md:64`）。supervisor 每轮轮询都可能重复下达 start，
///    如果 Fake 对「已在跑」抛错，supervisor 的重试逻辑会被测出一个假问题。
/// 2. **运行时不可用要能注入**。D3 的整个存在理由就是「apiserver 挂了又起来」——
///    这条路径不能注入，supervisor 的核心价值就没有测试覆盖。
@Suite("Fake 运行时：语义对齐真运行时，且失败可注入")
struct FakeContainerRuntimeClientTests {

    static func id(_ raw: String) throws -> ContainerID {
        try #require(ContainerID(raw))
    }

    static func container(_ raw: String, _ state: ContainerState) throws -> Container {
        Container(
            id: try id(raw),
            image: try #require(ImageRef("oomol/connector:1.0")),
            state: state,
            environment: []
        )
    }

    // MARK: - list

    @Test("list 返回种子容器")
    func listReturnsSeededContainers() async throws {
        let fake = FakeContainerRuntimeClient(containers: [
            try Self.container("db", .running),
            try Self.container("web", .stopped),
        ])

        let listed = try await fake.list()

        #expect(listed.count == 2)
        #expect(listed.map(\.id.rawValue) == ["db", "web"])  // 顺序确定，否则断言会随机红
    }

    // MARK: - start / stop

    @Test("start 把停着的容器拉起来")
    func startTransitionsToRunning() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])

        try await fake.start(id: try Self.id("db"))

        let listed = try await fake.list()
        #expect(listed[0].state == .running)
    }

    /// 幂等：supervisor 会重复下达 start（轮询间隔内容器可能还没起来）。
    /// 抛错就等于逼 supervisor 去区分「真失败」和「已经在跑了」——那是真运行时不要求它做的。
    @Test("start 已在跑的容器是幂等的，不抛错")
    func startIsIdempotent() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .running)])

        try await fake.start(id: try Self.id("db"))

        let listed = try await fake.list()
        #expect(listed[0].state == .running)
    }

    @Test("stop 把跑着的容器停下")
    func stopTransitionsToStopped() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .running)])

        try await fake.stop(id: try Self.id("db"))

        let listed = try await fake.list()
        #expect(listed[0].state == .stopped)
    }

    @Test("stop 已停的容器是幂等的，不抛错")
    func stopIsIdempotent() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])

        try await fake.stop(id: try Self.id("db"))

        let listed = try await fake.list()
        #expect(listed[0].state == .stopped)
    }

    /// 白名单里写了个不存在的容器（用户拼错了、或者容器被 `container delete` 掉了）——
    /// supervisor 必须区分得出这个和「运行时挂了」，否则它会把「ID 写错」当成
    /// 「apiserver 又挂了」，然后无限重试一个永远不会存在的容器。
    @Test("start 不存在的容器 → containerNotFound，不是 runtimeUnavailable")
    func startUnknownContainerReportsNotFound() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let ghost = try Self.id("ghost")

        await #expect(throws: RuntimeError.containerNotFound(ghost)) {
            try await fake.start(id: ghost)
        }
    }

    @Test("stop 不存在的容器 → containerNotFound")
    func stopUnknownContainerReportsNotFound() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let ghost = try Self.id("ghost")

        await #expect(throws: RuntimeError.containerNotFound(ghost)) {
            try await fake.stop(id: ghost)
        }
    }

    // MARK: - 错误注入

    /// D3 的核心场景：apiserver 挂了。没有这条注入，supervisor 最重要的一条路径无法测。
    @Test("可以注入 runtimeUnavailable")
    func injectsRuntimeUnavailable() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])
        await fake.inject(.runtimeUnavailable, for: .list)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            _ = try await fake.list()
        }
    }

    /// 注入是**按操作**的：apiserver 半死不活时，list 通了而 start 失败是真实存在的状态。
    /// 一个全局开关表达不出这个。
    @Test("注入只影响被指定的操作")
    func injectionIsScopedToOneOperation() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])
        await fake.inject(.runtimeUnavailable, for: .start)

        _ = try await fake.list()  // 不该抛

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            try await fake.start(id: try Self.id("db"))
        }
    }

    @Test("注入可以撤销")
    func injectionCanBeCleared() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])
        await fake.inject(.runtimeUnavailable, for: .start)
        await fake.inject(nil, for: .start)

        try await fake.start(id: try Self.id("db"))

        let listed = try await fake.list()
        #expect(listed[0].state == .running)
    }

    /// 注入的错误**不能**顺手改状态：失败的 start 必须让容器留在原地。
    /// 否则 supervisor 测试里「start 失败后重试」会因为状态已经变了而假绿。
    @Test("被注入错误的 start 不改变状态")
    func failedStartLeavesStateUntouched() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])
        await fake.inject(.runtimeUnavailable, for: .start)

        _ = try? await fake.start(id: try Self.id("db"))
        await fake.inject(nil, for: .start)

        let listed = try await fake.list()
        #expect(listed[0].state == .stopped)
    }

    // MARK: - 调用流水

    /// supervisor 的验收命题是「它有没有对**白名单里的**容器下达 start」——
    /// 那是个关于**副作用**的断言，光看最终状态答不了：
    /// 容器最后在跑，可能是 supervisor 拉的，也可能它本来就在跑。
    @Test("记录调用流水，供 supervisor 断言副作用")
    func recordsCallLog() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])
        let db = try Self.id("db")

        _ = try await fake.list()
        try await fake.start(id: db)
        try await fake.stop(id: db)

        let calls = await fake.calls
        #expect(calls == [.list, .start(db), .stop(db)])
    }

    /// 失败的调用也要留痕：「它试过但失败了」和「它压根没试」是两码事，
    /// supervisor 的重试测试正是要区分这两个。
    @Test("失败的调用也记进流水")
    func recordsFailedCalls() async throws {
        let fake = FakeContainerRuntimeClient(containers: [try Self.container("db", .stopped)])
        let db = try Self.id("db")
        await fake.inject(.runtimeUnavailable, for: .start)

        _ = try? await fake.start(id: db)

        let calls = await fake.calls
        #expect(calls == [.start(db)])
    }

    // MARK: - followLogs（T6，core 侧全链）

    /// 全链：`followLogs` → `LogTailer` → ring，明文遮蔽——证明这条链**穿过协议层**也成立，
    /// 不只是 `LogTailerTests` 里直接喂裸流的那种局部测试。
    @Test("followLogs 吐出配置好的行，接进 LogTailer 后已脱敏")
    func followLogsFeedsConfiguredLinesThroughTailer() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let secret = SecretString("sk-abcdef123456")
        await fake.setLogLines([LogLine(text: "token=sk-abcdef123456"), LogLine(text: "plain line")])

        let stream = try await fake.followLogs(id: try Self.id("db"))
        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: [secret]))
        await tailer.awaitDrained()

        let snapshot = await tailer.snapshot()
        #expect(snapshot.count == 2)
        #expect(!snapshot[0].text.contains("sk-abcdef123456"))
        #expect(snapshot[1].text == "plain line")
    }

    @Test("followLogs 可以注入失败——建流阶段的错误")
    func followLogsCanInjectFailure() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.runtimeUnavailable, for: .followLogs)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            _ = try await fake.followLogs(id: try Self.id("db"))
        }
    }

    /// 「挂起」：吐完配置好的行之后不 `finish()`——模拟一条仍然连着的流。
    /// `LogTailer.cancel()` 必须能在这种流上正确收工（`LogTailerTests` 已经单独测过这条，
    /// 这里只确认 Fake 真的能构造出这种流）。
    @Test("followLogs 支持挂起：吐完行之后流不 finish")
    func followLogsCanHangAfterLines() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setLogLines([LogLine(text: "only line")], hangsAfterLines: true)

        let stream = try await fake.followLogs(id: try Self.id("db"))
        let tailer = LogTailer(rawStream: stream, redaction: .resolved(secrets: []))

        while await tailer.snapshot().isEmpty {
            await Task.yield()
        }
        #expect(await tailer.status == .following, "流还挂着，不该被标成 streamEnded")

        await tailer.cancel()
    }

    @Test("followLogs 记进调用流水")
    func followLogsRecordsCall() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let db = try Self.id("db")

        _ = try await fake.followLogs(id: db)

        let calls = await fake.calls
        #expect(calls == [.followLogs(db)])
    }

    // MARK: - stats（T10，core 侧）

    @Test("stats 按顺序吐出配置好的样本（FIFO）")
    func statsReturnsSamplesInOrder() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setStatsSamples([
            ContainerStatsSample(memoryUsageBytes: 1),
            ContainerStatsSample(memoryUsageBytes: 2),
        ])
        let db = try Self.id("db")

        let first = try await fake.stats(id: db)
        let second = try await fake.stats(id: db)

        #expect(first.memoryUsageBytes == 1)
        #expect(second.memoryUsageBytes == 2)
    }

    @Test("stats 未配置样本时，返回全 nil 的样本而不是崩溃")
    func statsReturnsAllNilSampleWhenUnconfigured() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])

        let sample = try await fake.stats(id: try Self.id("db"))

        #expect(sample.cpuUsageUsec == nil)
        #expect(sample.memoryUsageBytes == nil)
    }

    @Test("stats 可以注入失败")
    func statsCanInjectFailure() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.operationFailed(reason: "xpc hiccup"), for: .stats)

        await #expect(throws: RuntimeError.operationFailed(reason: "xpc hiccup")) {
            _ = try await fake.stats(id: try Self.id("db"))
        }
    }

    @Test("stats 记进调用流水")
    func statsRecordsCall() async throws {
        let fake = FakeContainerRuntimeClient(containers: [])
        let db = try Self.id("db")

        _ = try await fake.stats(id: db)

        let calls = await fake.calls
        #expect(calls == [.stats(db)])
    }
}
