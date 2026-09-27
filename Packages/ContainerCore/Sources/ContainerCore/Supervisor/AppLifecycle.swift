import Foundation

/// App 的启动 / 退出编排（Day 22 codex R5 补评 P1）。纯编排、住 core：app target 没有测试 target。
///
/// ## 为什么需要一个令牌（CLAUDE.md ★「`await` 本身就是窗口」，本仓库第四次）
///
/// `start()` 挂在 `supervisor.start()` / 读白名单的 await 上时，退出（`stop()`）可以整段先做完：等升级、交接、停 supervisor。
/// 旧的 `start()` 续体随后恢复，照样开始恢复流程、起调度器——盘上若有崩溃遗留的意图记录，恢复会在 supervisor
/// 已停之后起运行时、拉容器。
///
/// → `stop()` 第一件事（同步、在任何 await 之前）把阶段推到 `.stopping`；`start()` 每跨过一个 await 都重新核对阶段，
///   「核对 + 开始后台工作」焊成一个同步操作（`beginBackgroundWork` 刻意是同步的）。
///
/// ## supervisor 最后收到的必须是「停」
///
/// actor 上的执行次序不由发起次序保证：`supervisor.start()` 的方法体可能晚于退出那句 `supervisor.stop()` 落地——
/// 它会清掉 `isStopped`、装上轮询循环。所以 `start()` 从 supervisor 那一步回来、发现退出已经停过 supervisor，就再停一次
/// （`Supervisor.stop()` 幂等）。退出还没走到停 supervisor 那一步时不抢着停：交接（settle）要一个活着的 supervisor。
///
/// ## 两次退出共用一次收尾
///
/// 第二次 `stop()` 等第一次那一份收尾，而不是立即返回：App 在它返回之后 `reply(toApplicationShouldTerminate:)`，
/// 提前放行 = 进程在交接 / 等升级做到一半时退出。
@MainActor
public final class AppLifecycle {

    public struct Steps {
        /// 启动时的同步准备（请求通知授权、接上更新通知）。**同步**：与 idle→starting 焊在一起——退出之后启动不再做任何事。
        public var beginStartup: @MainActor () -> Void
        public var startSupervisor: @MainActor () async -> Void
        /// 读界面用的白名单（排在 supervisor 之后：见 `AppModel.start()` 的注释）。
        public var loadWhitelist: @MainActor () async -> Void
        /// 恢复上一次没收完的升级、起自动检查的调度器。**同步**：与「还没开始退出」的核对焊在一起。
        public var beginBackgroundWork: @MainActor () -> Void
        /// 退出入口的同步准备（冻结白名单、更新器置 isTerminating，附录 C3）。
        public var beginQuit: @MainActor () -> Void
        /// 停调度器、等升级的 committed 阶段、有界交接（停 supervisor 之前的全部）。
        public var prepareForQuit: @MainActor () async -> Void
        public var stopSupervisor: @MainActor () async -> Void

        public init(
            beginStartup: @escaping @MainActor () -> Void,
            startSupervisor: @escaping @MainActor () async -> Void,
            loadWhitelist: @escaping @MainActor () async -> Void,
            beginBackgroundWork: @escaping @MainActor () -> Void,
            beginQuit: @escaping @MainActor () -> Void = {},
            prepareForQuit: @escaping @MainActor () async -> Void,
            stopSupervisor: @escaping @MainActor () async -> Void
        ) {
            self.beginStartup = beginStartup
            self.startSupervisor = startSupervisor
            self.loadWhitelist = loadWhitelist
            self.beginBackgroundWork = beginBackgroundWork
            self.beginQuit = beginQuit
            self.prepareForQuit = prepareForQuit
            self.stopSupervisor = stopSupervisor
        }
    }

    private enum Phase {
        case idle
        case starting
        case running
        /// 单向：进了就不再出来（没有「退出之后再启动」）。
        case stopping
    }

    private let steps: Steps
    private var phase: Phase = .idle
    /// 退出已经向 supervisor 发过「停」。
    private var supervisorStopIssued = false
    private var shutdown: Task<Void, Never>?
    private var quitBegun = false

    public init(steps: Steps) {
        self.steps = steps
    }

    public func start() async {
        guard phase == .idle else { return }
        phase = .starting
        steps.beginStartup()

        await steps.startSupervisor()
        guard phase == .starting else {
            // 我们的 start 可能晚于退出的 stop 落在 supervisor 上：再停一次。
            if supervisorStopIssued { await steps.stopSupervisor() }
            return
        }

        await steps.loadWhitelist()
        guard phase == .starting else { return }

        phase = .running
        steps.beginBackgroundWork()
    }

    /// 退出入口的同步准备，只做一次。`applicationShouldTerminate` 在建 `Task {}` **之前**调它：
    /// `stop()` 自己是 async 的、隔着一次调度，那一段里菜单照样收事件（T13 R6 #3 实测 popover 能打开）。
    public func beginQuit() {
        guard !quitBegun else { return }
        quitBegun = true
        steps.beginQuit()
    }

    public func stop() async {
        beginQuit()
        if let shutdown { return await shutdown.value }
        phase = .stopping
        let steps = self.steps
        let task = Task { @MainActor in
            await steps.prepareForQuit()
            self.supervisorStopIssued = true
            await steps.stopSupervisor()
        }
        shutdown = task
        await task.value
    }
}
