import Testing

@testable import ContainerCore

/// **D3 的落地测试。** prober 是 supervisor 判断「运行时还在不在、是不是换了一条命」的
/// 唯一可靠来源（R14：XPC 错误码区分不出运行时死活）。它判错，整台状态机就是瞎的。
@Suite("ApiserverProber")
struct ApiserverProberTests {

    private func prober(_ records: [ProcessRecord]) -> ApiserverProber {
        ApiserverProber(table: FakeProcessTable(records: records))
    }

    // MARK: - 基本判定

    @Test("apiserver 在进程表里 → running，令牌取自它的 (pid, startTime)")
    func running() async {
        let result = await prober(ProcessRecord.Real.withAPIServer).probe()

        #expect(result == .running(RuntimeGeneration(
            pid: ProcessRecord.Real.apiserver.pid,
            startTime: ProcessRecord.Real.apiserver.startTime
        )))
    }

    @Test("apiserver 不在 → down（其余 container 相关进程都还在，也不算数）")
    func down() async {
        #expect(await prober(ProcessRecord.Real.withoutAPIServer).probe() == .down)
    }

    @Test("进程表为空 → down")
    func emptyTable() async {
        #expect(await prober([]).probe() == .down)
    }

    // MARK: - ★ 干扰项：这条测试钉死的是一个实测到的坑

    /// `/usr/local/libexec/container/plugins/machine-apiserver/bin/machine-apiserver`
    /// **此刻就在这台 Mac 上跑着**，名字里同样带 "apiserver"。
    ///
    /// 若匹配规则是「路径**包含** apiserver」，它会被误认成运行时：
    /// - apiserver 真的挂了时，prober 仍报 running（拿的是 machine-apiserver 的令牌）
    ///   → **`.runtimeDown` 永远不会发生 → 核心场景下 reconcile 永远不触发**；
    /// - 两个进程都在时，令牌取谁不确定 → 令牌抖动 → **反复误 reconcile**。
    ///
    /// 所以匹配必须是**完整可执行路径全等**。这条测试是那条规则的红灯。
    @Test("machine-apiserver 名字里也有 apiserver，绝不能被当成运行时")
    func machineAPIServerIsNotTheRuntime() async {
        let onlyDecoys = [
            ProcessRecord.Real.machineAPIServer,
            ProcessRecord.Real.containerManagerd,
            ProcessRecord.Real.networkPlugin,
        ]

        #expect(await prober(onlyDecoys).probe() == .down)
    }

    @Test("路径只是前缀/后缀相似也不算（子串匹配会误判）")
    func similarPathsAreNotTheRuntime() async {
        let lookalikes = [
            ProcessRecord(pid: 1, executablePath: "/usr/local/bin/container-apiserver-shim", startTime: 1),
            ProcessRecord(pid: 2, executablePath: "/opt/homebrew/bin/container-apiserver", startTime: 2),
            ProcessRecord(pid: 3, executablePath: "/usr/local/bin/container-apiserverd", startTime: 3),
        ]

        #expect(await prober(lookalikes).probe() == .down)
    }

    // MARK: - 多命中：选择必须是确定的

    /// 同一路径出现两个进程（fork 中、或旧实例还没退干净）时，**取 startTime 最早的那个**。
    ///
    /// 规则本身取哪个不重要，**它必须是确定的**才重要：若取「进程表里的第一个」，
    /// 而进程表的顺序由内核决定、两次调用可能不同 → 令牌在两个 pid 之间来回跳 →
    /// reducer 每次都看到「换代了」→ **无限 reconcile**。
    @Test("同一路径多个进程 → 取 startTime 最早的，且与进程表顺序无关")
    func multipleMatchesPickOldest() async {
        let old = ProcessRecord(pid: 100, executablePath: ApiserverProber.defaultExecutablePath, startTime: 1_000)
        let new = ProcessRecord(pid: 200, executablePath: ApiserverProber.defaultExecutablePath, startTime: 2_000)

        let expected = ProbeResult.running(RuntimeGeneration(pid: 100, startTime: 1_000))

        #expect(await prober([old, new]).probe() == expected)
        #expect(await prober([new, old]).probe() == expected)
    }

    // MARK: - 令牌语义

    @Test("同一进程重复探测 → 令牌相等（稳态不该被当成换代）")
    func stableGeneration() async {
        let p = prober(ProcessRecord.Real.withAPIServer)

        #expect(await p.probe() == p.probe())
    }

    /// D3 的核心命题：**运行时换了一条命，令牌就必须变**——哪怕 pid 被系统复用。
    @Test("pid 相同但 startTime 不同 → 令牌不同（pid 复用不会漏判换代）")
    func pidReuseStillChangesGeneration() async {
        let path = ApiserverProber.defaultExecutablePath
        let first = await prober([ProcessRecord(pid: 42, executablePath: path, startTime: 1_000)]).probe()
        let second = await prober([ProcessRecord(pid: 42, executablePath: path, startTime: 9_999)]).probe()

        #expect(first != second)
    }

    @Test("可执行路径可注入（测试与部署位置解耦）")
    func customExecutablePath() async {
        let custom = "/opt/container/bin/apiserver"
        let table = FakeProcessTable(records: [
            ProcessRecord.Real.apiserver,
            ProcessRecord(pid: 7, executablePath: custom, startTime: 77),
        ])
        let prober = ApiserverProber(table: table, executablePath: custom)

        #expect(await prober.probe() == .running(RuntimeGeneration(pid: 7, startTime: 77)))
    }
}
