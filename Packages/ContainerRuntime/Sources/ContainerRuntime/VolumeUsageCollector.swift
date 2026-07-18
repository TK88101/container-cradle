import Foundation

/// usage enrichment 的调度器：**并发上限 + 全局预算，预算形状 = no-wait + 闭门**。
///
/// ## 为什么长这个样子（Day 10 计划审阅四轮裁决的落点，DAY10-DEVPLAN ★R1/★R3/★R4/★R5）
///
/// - **并发上限 4**（★R1）：几十个大卷不许同时打满 apiserver / 磁盘。
/// - **全局预算**（★R3）：全员超时的机器上 `ceil(N/4) × 5s` 是分钟级——列表不许挂那么久。
///   预算到点直接返回部分结果，没拿到的卷 `usedBytes = nil`（UI 显示「用量未知」）。
/// - **no-wait**（★R4）：预算到点**不等**在飞的调用（`XPCTimeout` 同款 continuation 形状）。
///   task group 做不出这个——group 返回前会等全部子任务，`cancelAll()` 唤不醒
///   不响应取消的 XPC 挂死（★ 血训，`XPCTimeout` 注释里有完整尸检）。
/// - **闭门**（★R5）：预算到点后**不再启动新调用**——预算钉的是**副作用总量**，
///   不只是 UI latency（UI 8 秒返回而后台继续扫 80 秒，同样违背 V2）。
///   允许泄漏的只有预算触发那一刻已在飞的 ≤4 个。
///
/// ## 单次使用
///
/// 一次 `collect` 就是一场比赛。actor 隔离让「预算到点」「单卷完成」「全部完成」
/// 三个并发事件的判定天然串行——不需要再手搓一把锁。
actor VolumeUsageCollector {

    private let fetch: @Sendable (String) async throws -> UInt64
    private let maxConcurrent: Int

    private var pending: [String] = []
    private var results: [String: UInt64] = [:]
    private var inFlight = 0

    /// 预算到点或全部完成后为 true。**闭门之后 `startWorkers` 一个新调用都不许发。**
    private var closed = false

    private var continuation: UnsafeContinuation<[String: UInt64], Never>?

    init(
        maxConcurrent: Int = 4,
        fetch: @escaping @Sendable (String) async throws -> UInt64
    ) {
        self.maxConcurrent = maxConcurrent
        self.fetch = fetch
    }

    /// 在 `budget` 内尽力收集每卷的真实占用。**永不抛错、永不超过预算太多**：
    /// 拿不到的卷就是不在返回的字典里。
    func collect(names: [String], budget: Duration) async -> [String: UInt64] {
        guard !names.isEmpty else { return [:] }
        pending = names

        return await withUnsafeContinuation { cont in
            continuation = cont

            // 预算计时器。`try?`：计时器没人取消，睡满了就该干活。
            Task {
                try? await Task.sleep(for: budget)
                await self.budgetFired()
            }

            startWorkers()
        }
    }

    private func startWorkers() {
        while !closed, inFlight < maxConcurrent, !pending.isEmpty {
            let name = pending.removeFirst()
            inFlight += 1

            Task {
                // `try?`：单卷失败/超时 = 该卷没有数据（fail-soft），不是整场失败。
                let value = try? await fetch(name)
                await self.finished(name: name, value: value)
            }
        }

        // 预算没到就全部做完 → 立刻交卷，别让调用方干等预算。
        if !closed, inFlight == 0, pending.isEmpty {
            settle()
        }
    }

    private func finished(name: String, value: UInt64?) {
        inFlight -= 1
        if let value { results[name] = value }

        // ★R5 闭门：预算到点后回来的在飞调用只是记账（结果已交卷、改不了了），
        // **绝不**再从 pending 里取新活。
        guard !closed else { return }
        startWorkers()
    }

    private func budgetFired() {
        // 已经全部做完、正常交卷了 → 计时器迟到，无事发生。
        guard !closed else { return }
        settle()
    }

    /// 交卷 = 闭门 + resume 恰好一次。「预算到点」与「全部完成」会抢，
    /// continuation 取走即置 nil，后到的是 no-op（`XPCTimeout.settle` 同款纪律）。
    private func settle() {
        closed = true
        let cont = continuation
        continuation = nil
        cont?.resume(returning: results)
    }
}
