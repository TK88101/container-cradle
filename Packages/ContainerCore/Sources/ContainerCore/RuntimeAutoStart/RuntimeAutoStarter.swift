import Foundation
import Observation

/// 重启 Mac 之后把运行时起回来（Day 23，Plan 2026-09-29-runtime-autostart）。
///
/// ## 为什么需要它
///
/// 上游的 apiserver 是 `container system start` 时才 `launchctl bootstrap` 进 gui 域的 launch agent，plist 不在 `~/Library/LaunchAgents`——
/// **重启 / 重新登录后运行时不会自己起来**。supervisor 只会在「运行时回来」的边沿拉白名单容器，而没有人去起运行时，这个边沿永远不来。
/// 这里只补「起运行时」这一步，其余全交给现有 supervisor。
///
/// ## 调用时机是正确性的一部分
///
/// 必须在 supervisor 首次探测**之后**（`AppLifecycle.beginBackgroundWork`）：那时 supervisor 已看见 `.runtimeDown`，我们起运行时 ⇒ 正常边沿 ⇒ reconcile。
/// 抢在它之前，首次探测会看见「已在跑」走冷启动 baseline、什么都不拉。成功后的 `reconcileManagedNow` 兜住 baseline 情形。
///
/// ## 与更新器互斥
///
/// 更新器是另一个会起停运行时的人。启动那一刻向它拿租约（它忙 / 有待补的恢复就拿不到），root 锁在跑也让路——这些都是**延后**不是失败：
/// 每 `retryInterval` 重判一次，最多 `maxDeferrals` 次（codex R1 #2 / R2 a：没有从 store 回调过来的钩子，重入问题不存在）。
///
/// ## 跨 await 重新证明（CLAUDE.md ★）
///
/// 每一轮带递增的 `run` 号；任何 await 回来先核对「还是这一轮、没在退出、没被取消」，不是就闭嘴退出，不写状态、不通知、不 reconcile。
/// 租约三处释放、谁先到谁生效（store 那边幂等）：正常路径在 reconcile 之前、`defer` 兜底、`beginTermination()` 同步——
/// 挂死在不响应取消的 await 上时 `defer` 永远到不了（codex R3），退出不许留下一个永久 busy 的更新器。
@MainActor
@Observable
public final class RuntimeAutoStarter {

    public enum State: Sendable, Equatable {
        case idle
        /// 第几次、何时重判只进日志（`log.deferred`），UI 只显示原因（simplify R1：带在状态里没人读）。
        case deferred(RuntimeAutoStartDeferral)
        case starting
        case failed(RuntimeAutoStartFailure)
    }

    /// 延后之后多久重判。
    public static let retryInterval: TimeInterval = 30
    /// 最多延后几次（30s × 20 = 10 分钟：覆盖一次真实升级——下载 118 MB 实测 206 秒 + 安装）。
    public static let maxDeferrals = 20

    /// UI 的唯一来源（codex R2 f）。
    public private(set) var state: State = .idle

    /// 「启动时自动恢复受管容器」开关，写入即落盘。退出开始之后不写（同更新器 R7 纪律）。
    public var isEnabled: Bool {
        didSet {
            guard !isTerminating else { return }
            preferences.isEnabled = isEnabled
        }
    }

    public private(set) var isTerminating = false

    /// 启动路径失败 ⇒ App 发系统通知（用户登录时不看菜单；静默失败 = 这个 bug 重演）。按钮路径不发：用户就在看横幅。
    @ObservationIgnored public var onFailure: (@MainActor (RuntimeAutoStartFailure) -> Void)?

    @ObservationIgnored private let commands: any RuntimeStarting
    @ObservationIgnored private let arbiter: any RuntimeOperationArbitrating
    @ObservationIgnored private let preferences: any RuntimeAutoStartPreferences
    @ObservationIgnored private let clock: any SupervisorClock
    @ObservationIgnored private let log: any RuntimeAutoStartLog
    @ObservationIgnored private let hasManagedContainers: @MainActor () async -> Bool
    @ObservationIgnored private let reconcileManagedNow: @MainActor () async -> Void

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var heldToken: ExternalRuntimeToken?
    @ObservationIgnored private var launchClaimed = false
    @ObservationIgnored private var run = 0

    public init(
        commands: any RuntimeStarting,
        arbiter: any RuntimeOperationArbitrating,
        preferences: any RuntimeAutoStartPreferences,
        clock: any SupervisorClock = SystemSupervisorClock(),
        log: any RuntimeAutoStartLog = OSLogRuntimeAutoStartLog(),
        hasManagedContainers: @escaping @MainActor () async -> Bool,
        reconcileManagedNow: @escaping @MainActor () async -> Void
    ) {
        self.commands = commands
        self.arbiter = arbiter
        self.preferences = preferences
        self.clock = clock
        self.log = log
        self.hasManagedContainers = hasManagedContainers
        self.reconcileManagedNow = reconcileManagedNow
        self.isEnabled = preferences.isEnabled
    }

    // MARK: - 入口

    /// App 启动时调用（`beginBackgroundWork`，`recoverIfNeeded()` 之后）。每个进程生命只认领一次。
    public func startOnLaunchIfNeeded() {
        guard !launchClaimed else { return }
        launchClaimed = true
        begin(.appLaunch)
    }

    /// 横幅「启动运行时」。在途时忽略（不并发起两次）；延后等待中 ⇒ 取消等待、立刻重判（codex R2 b）。
    public func startNow() {
        guard state != .starting else { return }
        begin(.userButton)
    }

    /// 退出入口同步调（`AppLifecycle.beginQuit`）：单向置位、取消 task、**同步**归还租约。
    public func beginTermination() {
        isTerminating = true
        task?.cancel()
        if let token = heldToken {
            heldToken = nil
            arbiter.endExternalRuntimeOperation(token)
        }
    }

    /// 测试用：等当前这一轮走完，**有界**。并发缺陷（例如租约不还）在这里的表现是「永远等不到下一步」——
    /// 裸 `await task.value` 不响应取消，连 Swift Testing 的 `.timeLimit` 都叫不醒（突变 M7 实测挂死）。
    /// 等不到就返回，交给调用方之后的断言变红（continuation + 不等，同 CLAUDE.md 超时约定）。
    func awaitRunForTests(within limit: Duration = .seconds(10)) async {
        while let current = task {
            guard (try? await XPCTimeout.race(after: limit) { await current.value }) != nil else { return }
            if task == current { break }
        }
    }

    // MARK: - 流程

    private func begin(_ trigger: RuntimeAutoStartTrigger) {
        guard !isTerminating else { return }
        task?.cancel()
        run += 1
        let run = self.run
        task = Task { await self.execute(trigger, run: run) }
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == self.run && !isTerminating && !Task.isCancelled
    }

    /// 一轮：尝试 → 被延后就等 `retryInterval` 再试，最多 `maxDeferrals` 次。
    private func execute(_ trigger: RuntimeAutoStartTrigger, run: Int) async {
        var deferrals = 0
        while let reason = await attempt(trigger, run: run) {
            guard isCurrent(run) else { return }
            deferrals += 1
            guard deferrals <= Self.maxDeferrals else {
                return fail(.blockedByUpdater, trigger: trigger, detail: nil)
            }
            state = .deferred(reason)
            log.deferred(trigger: trigger, reason: reason, attempt: deferrals)
            let deadline = await clock.now().addingTimeInterval(Self.retryInterval)
            guard isCurrent(run) else { return }
            await clock.sleep(until: deadline)
            guard isCurrent(run) else { return }
        }
    }

    /// 尝试一次。返回非 nil = 被延后（原因）；nil = 这一轮结束（成功、跳过、失败，或世界已变）。
    private func attempt(_ trigger: RuntimeAutoStartTrigger, run: Int) async -> RuntimeAutoStartDeferral? {
        if trigger == .appLaunch, !isEnabled { return skip(.disabled, trigger: trigger) }
        guard arbiter.isPrimaryInstance else { return skip(.notPrimary, trigger: trigger) }
        if trigger == .appLaunch {
            let hasManaged = await hasManagedContainers()
            guard isCurrent(run) else { return nil }
            guard hasManaged else { return skip(.noManagedContainers, trigger: trigger) }
        }
        if arbiter.pendingIntentOwesRuntimeStart { return .updaterOwesRuntimeStart }
        guard let token = arbiter.tryBeginExternalRuntimeOperation() else { return .updaterBusy }
        heldToken = token
        defer { release(token) }
        state = .starting

        let alreadyRunning = await commands.isRuntimeRunning()
        guard isCurrent(run) else { return nil }
        if alreadyRunning { return skip(.alreadyRunning, trigger: trigger) }

        let lock = await commands.privilegedJobState()
        guard isCurrent(run) else { return nil }
        switch lock {
        case .running: return .privilegedJobRunning
        case .probeFailed: return .lockProbeFailed
        case .idle: break
        }

        let allowKernelInstall = trigger == .userButton
        log.started(trigger: trigger, kernelInstall: allowKernelInstall)
        let outcome = await commands.startRuntime(allowKernelInstall: allowKernelInstall)
        guard isCurrent(run) else { return nil }
        if let (failure, detail) = Self.failure(for: outcome) {
            fail(failure, trigger: trigger, detail: detail)
            return nil
        }

        let isUp = await commands.isRuntimeRunning()
        guard isCurrent(run) else { return nil }
        // reconcile 之前还租约：它不与更新器争运行时（更新器自己的复原也调它），且它不等 reconcile 做完（codex R5）。
        release(token)
        guard isUp else {
            fail(.notReady, trigger: trigger, detail: nil)
            return nil
        }
        state = .idle
        log.succeeded(trigger: trigger)
        await reconcileManagedNow()
        return nil
    }

    // MARK: - 共用

    private func skip(_ reason: RuntimeAutoStartSkip, trigger: RuntimeAutoStartTrigger) -> RuntimeAutoStartDeferral? {
        state = .idle
        log.skipped(trigger: trigger, reason: reason)
        return nil
    }

    private func fail(_ failure: RuntimeAutoStartFailure, trigger: RuntimeAutoStartTrigger, detail: String?) {
        state = .failed(failure)
        log.failed(trigger: trigger, failure: failure, detail: detail)
        if trigger == .appLaunch { onFailure?(failure) }
    }

    private func release(_ token: ExternalRuntimeToken) {
        if heldToken == token { heldToken = nil }
        arbiter.endExternalRuntimeOperation(token)
    }

    /// `nil` = 成功。`detail` = CLI stderr 尾巴（只进 `.private` 日志）。
    static func failure(for outcome: CommandOutcome) -> (RuntimeAutoStartFailure, detail: String?)? {
        switch outcome {
        case .succeeded: nil
        case .failed(let exitCode, let detail): (.commandFailed(exitCode: exitCode), detail)
        case .timedOut: (.timedOut, nil)
        case .notInstalled: (.notInstalled, nil)
        }
    }
}
