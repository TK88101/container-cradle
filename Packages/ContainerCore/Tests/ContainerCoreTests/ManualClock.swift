import Foundation

@testable import ContainerCore

/// 手动推进的时钟。**测试里一秒都不真睡。**
///
/// 退避封顶是 5 分钟、熔断窗口是 10 分钟——靠真实时间去撞这些分支，一条测试要跑十分钟，
/// 于是没人会写它，于是它们没有测试。这里「等 10 分钟」是一行 `advance(by: 600)`。
actor ManualClock: SupervisorClock {

    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Never>)] = [:]

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = now
    }

    func now() -> Date { current }

    /// **必须响应取消**：`Supervisor.stop()` 会 cancel 一个正在睡的 tick task，
    /// 不处理取消的话那条 continuation 永远不会被 resume——测试挂死，生产里是 task 泄漏。
    func sleep(until deadline: Date) async {
        guard current < deadline else { return }

        let id = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sleepers[id] = (deadline, continuation)
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
    }

    /// 把时间往前推，叫醒所有到点的睡眠者。
    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)

        for (id, sleeper) in sleepers where sleeper.deadline <= current {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    private func wake(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume()
    }
}

/// **可闸住的 prober。** 用来把测试精确地卡进「`start()` 正挂在首次 probe 上」那个窗口，
/// 而不是靠 sleep 去撞——竞态测试若靠 sleep，它要么是假绿，要么是间歇性红。
actor GatedProber: RuntimeProber {

    private let result: ProbeResult
    private(set) var probeCount = 0

    private var entered: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(_ result: ProbeResult) {
        self.result = result
    }

    func probe() async -> ProbeResult {
        probeCount += 1

        // 告诉测试：我进来了。
        entered?.resume()
        entered = nil

        // 然后卡住，直到测试放行。（放行过一次之后就不再卡——
        // 否则被装上去的轮询循环会在第二次 probe 上停住，测试就看不出它还活着。）
        if !isReleased {
            await withCheckedContinuation { gate = $0 }
        }

        return result
    }

    /// 等到 probe 真的进来了。
    func waitUntilProbing() async {
        guard probeCount == 0 else { return }

        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }
}

/// **可闸住的 reconcile engine。** 把测试精确地卡进「reconcile 正在途中」那个窗口，
/// 好在那时候插一个 `stop()` 进去。
actor GatedEngine: ReconcileEngine {

    private let outcome: ReconcileOutcome

    private var entered: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var isReconciling = false

    init(outcome: ReconcileOutcome) {
        self.outcome = outcome
    }

    /// 已经返回过结果了。测试靠它知道「那条回投 Task 该跑到 deliver 了」。
    private(set) var hasReturned = false

    func reconcile(generation: RuntimeGeneration) async -> ReconcileOutcome {
        isReconciling = true
        entered?.resume()
        entered = nil

        await withCheckedContinuation { gate = $0 }

        hasReturned = true
        return outcome
    }

    func waitUntilReconciling() async {
        guard !isReconciling else { return }

        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    /// 等到那条 reconcile Task 已经拿到结果、并且走完了回投那一跳。
    ///
    /// `stop()` 之后 `Supervisor.reconcileTask` 已被置 nil，`awaitReconcile()` 等不到它——
    /// 那条 Task 变成了孤儿，但它**还在跑**，而它跑到哪一步正是这条测试要验的东西。
    /// 让出足够多次调度点，把那一跳跑完。
    func settle() async {
        while !hasReturned {
            await Task.yield()
        }

        // 结果已返回；再让出若干次，把「回投 → deliver」那一跳跑完。
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}

/// 探测结果可随时改写的 prober。「运行时挂了又起来」就是改一次这个值。
actor FakeRuntimeProber: RuntimeProber {

    private var result: ProbeResult

    init(_ result: ProbeResult = .down) {
        self.result = result
    }

    func set(_ result: ProbeResult) {
        self.result = result
    }

    func probe() -> ProbeResult { result }
}
