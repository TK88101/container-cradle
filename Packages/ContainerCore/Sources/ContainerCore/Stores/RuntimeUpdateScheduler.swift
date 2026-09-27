import Foundation

/// 自动检查的节奏（Day 22 T8，Plan §5.5）。
///
/// 启动后 60 秒第一次看是否到期，之后每小时看一次；**到期与否由 store 判**（距上次成功 ≥ 24h、不在限流期、开关开着、
/// 此刻没有在忙）。两个参数乘出来：新版本最迟 25 小时内被发现；最坏每天 24 次请求（失败的检查每小时重试一次），
/// 远低于 GitHub 未认证 60 次 / 小时的限额。
///
/// 为什么 tick 是 1 小时而不是直接睡 24 小时：Mac 会睡眠、App 会被登录项反复拉起——「距上次成功」存在偏好里，
/// 每小时对一次表，比依赖一个长睡眠的 Task 醒得准。
@MainActor
public final class RuntimeUpdateScheduler {

    public static let initialDelay: TimeInterval = 60
    public static let tickInterval: TimeInterval = 60 * 60

    private let store: RuntimeUpdateStore
    private let clock: any SupervisorClock
    private let initialDelay: TimeInterval
    private var task: Task<Void, Never>?

    public init(
        store: RuntimeUpdateStore,
        clock: any SupervisorClock = SystemSupervisorClock(),
        initialDelay: TimeInterval = RuntimeUpdateScheduler.initialDelay
    ) {
        self.store = store
        self.clock = clock
        self.initialDelay = initialDelay
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, clock, initialDelay] in
            await clock.sleep(until: await clock.now().addingTimeInterval(initialDelay))
            while !Task.isCancelled {
                self?.tick()
                await clock.sleep(until: await clock.now().addingTimeInterval(Self.tickInterval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        if store.isAutomaticCheckDue() { store.automaticCheck() }
    }
}
