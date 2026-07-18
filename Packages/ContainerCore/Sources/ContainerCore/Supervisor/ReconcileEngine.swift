/// **supervisor 的手。** 大脑（`reduce`）决定「该拉了」，这里真的去拉。
///
/// 抽成 protocol 是为了让 `Supervisor` actor 的测试不必真去起容器——
/// 那台 actor 要验的是「换代时有没有下达 reconcile、失败后有没有退避」，
/// 跟「拉容器的那串调用序列对不对」是两个独立命题。
public protocol ReconcileEngine: Sendable {

    /// 为这一代拉起白名单容器。**不抛错**——失败被归类成 `ReconcileOutcome`，
    /// 因为 reducer 要的不是「哪里错了」，而是「该退避、该熔断，还是该放弃」。
    ///
    /// - Parameter generation: 这一轮属于哪一代。engine 自己不拿它做判断（它只管拉），
    ///   但结果必须原样带回去——`Supervisor` 靠它做 stale 判定。
    func reconcile(generation: RuntimeGeneration) async -> ReconcileOutcome
}

/// 把白名单里 enabled 的容器逐个拉起来。
public struct WhitelistReconcileEngine: ReconcileEngine {

    private let client: any ContainerRuntimeClient
    private let whitelist: any WhitelistProvider

    /// **诊断出口**（Day 8）。Day 7「M3 红了却不知道为什么」的正解落点就在下面那个 catch：
    /// 那里 `error: RuntimeError` 在手，是唯一能记下「哪个容器、因为什么起不来」的地方。
    private let log: any SupervisorLog

    public init(
        client: any ContainerRuntimeClient,
        whitelist: any WhitelistProvider,
        log: any SupervisorLog = NullSupervisorLog()
    ) {
        self.client = client
        self.whitelist = whitelist
        self.log = log
    }

    /// ## 为什么不先 `list()` 一遍再挑该拉的
    ///
    /// `ContainerRuntimeClient` 保证 `start` 幂等（已在跑 → 静默成功）。先 list 只买到两样
    /// 东西：多一次 XPC 往返，和一个竞态窗口（list 完到 start 之间容器状态可能又变了）。
    ///
    /// ## 一个失败不中断其余
    ///
    /// 早退（第一个失败就 return）会让白名单的后半截在每次环境抖动时集体失守——
    /// 而那恰恰是最需要它们起来的时候。
    public func reconcile(generation: RuntimeGeneration) async -> ReconcileOutcome {
        var failures: [FailureKind] = []

        for entry in await whitelist.entries() where entry.enabled {
            do {
                try await client.start(id: entry.id)
            } catch {
                // ★ 诊断落点（Day 8）。带 generation（P1-5：可能是已被作废的旧世代，日志据此定位）；
                // error 的原始文本由 `SupervisorLog` 实现当不可信文本处理（.private）。
                // 不加 `as RuntimeError`：typed throws 的 catch 里 error 本就是 RuntimeError，
                // 加 `as` 会撞上 Swift 6.3.3 的 SILGen bug（见 CLAUDE.md）。
                log.containerStartFailed(id: entry.id, generation: generation, error: error)
                failures.append(FailureKind(from: error))
            }
        }

        guard let worst = failures.max(by: { $0.severity < $1.severity }) else {
            // 全成功；白名单为空也走这里——**没活干不是失败**。
            // 判成失败的话，还没配过白名单的新用户会看着 supervisor 不停退避、报错、
            // 最后熔断，为了「什么都不用做」这件事。
            return .success
        }

        return .failure(worst)
    }
}

extension FailureKind {

    /// **聚合优先级。** 一轮拉多个容器可能得到多种失败，而 reducer 只接受一个 outcome。
    ///
    /// `transient` > `environmentNotReady` > `permanent`，两头的理由各不相同：
    ///
    /// - **transient 必须最高**：否则只要有一块外置盘没插上（environmentNotReady 长期存在），
    ///   熔断就被**永久屏蔽**，真正 crashloop 的容器可以无限打铁。熔断当场变成摆设。
    ///   **残余风险（已知、已接受）**：熔断开了之后，本该继续等盘的容器也一起停了。
    ///   出口是菜单里的手动 "Start now"（`userForcedReconcile` 会把熔断清掉）。
    ///
    /// - **permanent 必须最低**：一个 ID 拼错的条目，不该让另一个正在等外置盘的容器
    ///   陪着一起被放弃。前者每轮白试一次（无害），后者必须继续退避重试。
    fileprivate var severity: Int {
        switch self {
        case .permanent: 0
        case .environmentNotReady: 1
        case .transient: 2
        }
    }
}
