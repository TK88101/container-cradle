import Foundation
import Observation

/// apple/container 运行时更新器的状态机（Day 22 T7，Plan §5.4）。**纯逻辑住 core、可测**；执行件全经 `RuntimeUpdateEnvironment`。
///
/// ## 三个入口写同一个目标（嗅觉库：两个入口写同一目标）
///
/// 通知的「立即更新」、菜单更新条的按钮、「检查更新」按钮——全都落到这里的同一组方法，单飞：
/// 任何时刻最多一个检查 / 升级 / 恢复在跑（`isBusy`）。自动检查进行中用户点了手动检查 → **合并**进那一次，
/// 结果为「可用」则直接升级（用户既裁定 D2：手动检查查到就装）。
///
/// ## 跨 await 重新证明自己还活在同一个世界（CLAUDE.md ★）
///
/// 每个操作带递增的 `operation` 号，副作用回来后凭号回写；号不符的结果不写状态。
///
/// ## 三种「没有」不折叠（Plan §4）
///
/// 未安装 / 读不出版本 / 查询失败 / 被限流，各有各的状态——**没有一条路径会把它们显示成「已是最新」**。
@MainActor
@Observable
public final class RuntimeUpdateStore {

    public enum State: Sendable, Equatable {
        case idle
        case checking
        case upToDate(RuntimeVersion)
        case available(installed: RuntimeVersion, release: RuntimeRelease)
        case skipped(installed: RuntimeVersion, release: RuntimeRelease)
        case checkFailed(CheckFailure)
        case notInstalled
        case updating(RuntimeRelease, UpdateStage)
        /// 启动时发现上一次升级没走完收尾（AD9）。
        case recovering
        /// `unrestored` = 升级前在跑、升级后没能拉回来的未受管容器（AD6）。
        case succeeded(RuntimeVersion, unrestored: [ContainerID])
        case cancelled
        /// `pending` = 还没复原的东西与原因（R4 B/C/D：「义务未了」「运行时停着」「为什么没复原」是三件事）。
        /// 「启动运行时」按钮看 `canStartRuntime`（义务），不看这里（R2 E）。
        case failed(UpdateFailure, pending: PendingRestore?)
        /// 另一个实例持着更新器的租约（R2 O）：本实例只读。
        case otherInstanceActive
    }

    public private(set) var state: State = .idle
    /// 当前阶段从什么时候开始（UI 显示已用时间：真下载 118 MB 实测 206 秒，F24 / 进度记录）。
    public private(set) var stageStartedAt: Date?
    /// 最近一次读到的已装版本（A9 的「未经测试」提示用）。
    public internal(set) var lastKnownInstalled: RuntimeVersion?

    /// 自动检查发现可用更新 → App 发系统通知（AD5）。
    public var onUpdateAvailable: (@MainActor (RuntimeRelease, RuntimeVersion) -> Void)?
    /// 运行时被我们停着、没能起回来 → App 发系统通知（用户可能已经关了菜单）。`because` = 为什么没起（R4 C）。
    /// 运行时在跑、只欠容器时**不**触发（R4 D：那时说「运行时停着」是假话）。
    public var onRuntimeLeftStopped: (@MainActor (_ failure: UpdateFailure, _ because: UpdateFailure) -> Void)?

    let environment: RuntimeUpdateEnvironment
    let preferences: any UpdatePreferences
    /// 本实例拿到了更新器的单实例租约（`InstanceLease`，R2 O）。拿不到 → 只读：不恢复、不检查、不安装、不启动运行时——
    /// 意图记录在 defaults 里与另一个实例共用，两个都动手就是两个启动者抢同一个运行时 / 容器。
    public let isPrimaryInstance: Bool

    var task: Task<Void, Never>?
    var operation = 0
    /// 自动检查进行中收到了手动检查（合并）。
    var manualRequested = false
    /// 本实例这一次升级 / 恢复的意图记录。**内存里这份是权威**，每次变更回写 defaults（崩溃恢复读那份）。
    /// 安全评审 L8：defaults 是多实例共享的——另一个实例启动时的恢复流程可能把它清掉；收尾若去读 defaults，
    /// 就会以为「从没停过运行时」而不复原。
    var activeIntent: UpdateIntent?
    /// 这一次任务自己走到了 ready（发过 stop 的前提）。**不落盘**：崩溃恢复只看记录里的 `stopIssued`——
    /// 它可能是这次发的，也可能是从上一次没收完的复原继承来的（R2 E）；这个标志只用来区分「这次的取消码是不是在 stop 之后」。
    var readyReached = false
    /// 附录 C4：这次操作在停机前读不到在跑容器、放弃了停机（root 的 stop-timeout 据此报 `.snapshotUnavailable`）。
    var abandonedOperation: Int?
    /// 此刻真在复原运行时（`system start` / 拉容器）——只有这一段算 committed，退出要等（R2 L）。
    var isRestoringRuntime = false
    /// 此刻在等 root 任务结束（osascript 没按契约结束之后，R5 P2-2）：这段**不算** committed——与恢复流程等锁同构（R2 L）。
    /// 锁可能被别的用户的任务占着，最长等一个小时；退出放行，记录（stopIssued 已落盘）留给下次启动的恢复流程。
    var isAwaitingJobEnd = false
    /// busy 期间到达的「运行时可能被别处起来了」触发（R5 P2-1）：supervisor 只在状态变化时投快照，挡掉的不会自己再来——
    /// 记下来，操作结束后补做一次。
    var restartCheckPending = false
    /// 启动恢复已经有过它的机会（`recoverIfNeeded()` 被调用过——不论它有没有真去恢复，R6 5a）。在那之前不开放手动复原：
    /// 冷启动时 supervisor 起来、白名单读完之前，按钮若从盘上的记录露出来，按下会抢先清掉记录，恢复流程就报不出状态文件的结论。
    /// 读白名单可能被网络家目录拖慢，这个窗口不保证短。
    var startupRecoveryClaimed = false
    /// 退出已经开始（`prepareForTermination()` 第一句置位，单向，R6）：之后不接受任何会起任务或写偏好的动作。
    /// 防御性：`.terminateLater` 期间 popover 是否还收事件**未实测（TBD）**——交接最长 60 秒，那时开的新操作没有任何东西等它。
    public private(set) var isTerminating = false
    /// 启动恢复到达时 store 正忙、被挡掉的那份盘上记录（R7 D）：例如冷启动卡在读白名单时用户抢先点了「检查更新」。
    /// 操作结束时若盘上记录**仍是这一份**就补做恢复；被本会话的升级接手（写成新 nonce）或已消失就丢弃。只记有义务的记录。
    var deferredRecoveryNonce: UUID?

    public init(environment: RuntimeUpdateEnvironment, preferences: any UpdatePreferences, isPrimaryInstance: Bool = true) {
        self.environment = environment
        self.preferences = preferences
        self.isPrimaryInstance = isPrimaryInstance
        self.isAutomaticCheckEnabled = preferences.isAutomaticCheckEnabled
        if !isPrimaryInstance { state = .otherInstanceActive }
    }

    // MARK: - 查询

    public var isBusy: Bool {
        switch state {
        case .checking, .updating, .recovering: true
        default: false
        }
    }

    /// 运行时可能正被我们停着、且我们正在处理它的阶段——App 退出要等它走完（Plan §5.4「App 退出」列）。
    /// `.recovering` 整段**不**算：等锁的那段什么都没动，退出立即放行、记录留着下次再恢复（R2 L）；只有真在复原时算。
    public var isInCommittedPhase: Bool {
        if isAwaitingJobEnd { return false }
        if case .updating(_, let stage) = state, stage.isCommitted { return true }
        return isRestoringRuntime
    }

    /// 「启动运行时」可用：有一份**未解决**的「我们停过、升级前在跑」的意图记录，且此刻不忙（R2 E）。
    /// 不只看 state——失败态会被之后的检查覆盖，义务不会；按钮跟着义务走。
    /// 启动恢复还没机会认领之前、退出开始之后都不可用（R6）。
    public var canStartRuntime: Bool {
        isPrimaryInstance && startupRecoveryClaimed && !isTerminating && !isBusy && unresolvedStop != nil
    }

    /// 手动复原按钮：显示与否、标题——**view 只看这一个来源**（codex R5 补评 D，辩论 3 轮收敛）。`nil` = 不显示。
    ///
    /// 只认义务，不看 state / pending：`.failed(_, .runtimeStopped)` 只是上一次观测——已解除的义务不再理会 supervisor 的触发，
    /// 用户在终端起好运行时之后 state 仍停在那里，按它写「Start Runtime」就是假话（按下只拉容器）。
    /// 反过来「启动剩余容器」是目标型标题：解除之后运行时若又被用户停了，按下会先起运行时（手动按钮例外，R4 E）。
    public var manualRestore: ManualRestore? {
        guard canStartRuntime, let intent = unresolvedStop else { return nil }
        return intent.owesRuntimeStart ? .startRuntime : .startRemainingContainers
    }

    /// 未解决的复原义务（内存那份优先；App 刚启动、恢复还没跑时读 defaults）。
    /// 纯容器欠账（R4 E）只在内存里——它不落盘，所以 `activeIntent` 必须排在前面。
    var unresolvedStop: UpdateIntent? {
        guard let intent = activeIntent ?? preferences.intent, intent.hasObligation else { return nil }
        return intent
    }

    /// D4 开关。存一份可观察的副本（偏好本身不是 `@Observable`，Toggle 改了要能刷新），写入即落盘。
    public var isAutomaticCheckEnabled: Bool {
        didSet {
            // 退出开始之后不写偏好（R7）：内存里的值随它去（进程马上结束），盘上不动；界面上的开关同时禁用。
            guard !isTerminating else { return }
            preferences.isAutomaticCheckEnabled = isAutomaticCheckEnabled
        }
    }

    /// 自动检查此刻是否到期（调度器用）。
    public func isAutomaticCheckDue() -> Bool {
        isPrimaryInstance && !isTerminating && !isBusy && UpdatePolicy.isCheckDue(
            now: environment.now(),
            lastSuccess: preferences.lastSuccessfulCheck,
            rateLimitedUntil: preferences.rateLimitedUntil,
            isEnabled: isAutomaticCheckEnabled
        )
    }

    // MARK: - 用户 / 调度器的动作

    public func automaticCheck() { startCheck(.automatic) }

    /// 「检查更新」按钮：查到新版就直接升级（D2）。
    public func checkForUpdates() { startCheck(.manual) }

    /// 通知的「立即更新」：store 还持有可用版本就直接装，否则（例如 App 重启过）走一次手动检查。
    public func updateNow() {
        switch state {
        case .available, .skipped: install()
        default: checkForUpdates()
        }
    }

    public func install() {
        guard isPrimaryInstance, !isTerminating, !isBusy else { return }
        switch state {
        case .available(let installed, let release), .skipped(let installed, let release):
            let op = beginOperation(.updating(release, .downloading))
            task = Task {
                await self.runInstall(release, from: installed, op: op)
                self.operationEnded()
            }
        default:
            return
        }
    }

    public func skip() {
        if case .available(_, let release) = state { skip(version: release.version) }
    }

    /// 通知动作带着版本号（store 可能不在 available 态）。
    public func skip(version: RuntimeVersion) {
        // 写偏好（下次启动与自动检查都认它），是持久化动作：退出开始之后不接（R6）。
        guard isPrimaryInstance, !isTerminating else { return }
        preferences.skippedVersion = version
        if case .available(let installed, let release) = state, release.version == version {
            state = .skipped(installed: installed, release: release)
        }
    }

    /// 「稍后」：收起更新条，下次自动检查（≥24h）再提醒。
    public func later() {
        if case .available = state { state = .idle }
    }

    /// 有未解决的复原义务时的「启动运行时」（**锁空闲才动**，A8）。失败态被覆盖之后照样可用（R2 E）。
    public func startRuntime() {
        guard canStartRuntime else { return }
        // 执行期间算 busy（codex R1 [P2]：否则按钮连点会并发起两次运行时）。
        let previous = state
        let op = beginOperation(.recovering)
        task = Task {
            await self.runManualStart(op: op, restoring: previous)
            self.operationEnded()
        }
    }

    /// supervisor 看到运行时在跑——**只是触发，不是证据**（R4 E-6'）。
    ///
    /// 快照是跨 actor 异步投递的（`SupervisorStatusStore.observer()`），可能生成于我们 stop 之前、晚到；sequence 只保证不倒退，
    /// busy 过滤只是消费时的过滤。证据只认触发之后的一次**新鲜探测**（因而必然在我们的 stop 之后）：
    /// 探测为真 ⇒ 别处 / 用户已把它起来了 ⇒「起运行时」义务解除（我们不再替任何人起它），只剩本次会话里的容器欠账；
    /// 菜单上「运行时停着」这句也随之改掉（否则用户手动起来之后它一直是假话）。
    ///
    /// **只看本次会话里的义务**（`activeIntent`，R5 P1-1）：落盘的义务归恢复流程。冷启动时 supervisor 的首份快照先于
    /// `recoverIfNeeded()` 到达（它的 MainActor 任务排在 `AppModel.start()` 的续体之前）——这里若去读 defaults，
    /// 就会抢在恢复之前把记录清掉，整段恢复（拉容器、请受管 reconcile、报状态文件的结论）被绕过。恢复一开始就会置 `activeIntent`。
    public func runtimeMayHaveRestarted() {
        guard isPrimaryInstance, !isTerminating else { return }
        guard !isBusy else {
            restartCheckPending = true
            return
        }
        guard let intent = activeIntent, needsRestartConfirmation(intent) else { return }
        let op = operation
        // 确认任务单飞（R7 A）：走到这里说明不 busy，槽里要么是已结束的操作、要么是上一个确认任务——取消它，
        // 否则 supervisor 连投两份快照就会留下一个孤儿，退出只取消得到槽里那一个。
        task?.cancel()
        task = Task { await self.confirmRuntimeRestarted(intent, op: op) }
    }

    /// 值得为「运行时可能被别处起来了」做一次新鲜探测：欠「起运行时」；或义务已解除、但状态行还说着「运行时停着」
    /// （手动启动被锁挡住 / 起失败时留下的，R6 #4）——不探一次，这句话会在用户起好运行时之后一直是假话。
    /// state 只当**触发条件**，证据仍是之后那次新鲜探测（E-6'）。
    func needsRestartConfirmation(_ intent: UpdateIntent) -> Bool {
        if intent.owesRuntimeStart { return true }
        guard intent.hasObligation, case .failed(_, .runtimeStopped?) = state else { return false }
        return true
    }

    /// 一个操作结束（回到非 busy）：补做期间被挡掉的触发（R5 P2-1）。退出途中（任务被取消）不补。
    func operationEnded() {
        guard !Task.isCancelled, !isBusy else { return }
        // 先补恢复（R7 D）：盘上记录仍是当时被挡掉的那一份才补。退出途中由 `recoverIfNeeded` 自己的 `isTerminating` 挡住。
        if let nonce = deferredRecoveryNonce {
            deferredRecoveryNonce = nil
            if preferences.intent?.nonce == nonce { recoverIfNeeded() }
        }
        // 再补重启确认。补做的恢复若已开始（busy），确认留到它结束时的这里（codex R7：先恢复、后确认）。
        // 退出等着的 committed 操作走完时也不补——挡它的是 `runtimeMayHaveRestarted` 入口那道 `isTerminating`（R6；这里不再重复一道：
        // 两道闸会让其中一道测不到，R6 突变实测）。
        guard restartCheckPending, !isBusy else { return }
        restartCheckPending = false
        runtimeMayHaveRestarted()
    }

    /// App 启动时调用（AD9）。记录只读这一次、直接交给恢复任务（R2 M：读两次，中间被清掉就永远卡在 recovering）。
    public func recoverIfNeeded() {
        // 认领写在所有 guard 之前：恢复被 busy 等挡掉时，盘上的记录照旧可以手动处理（既有行为）；只关掉「恢复还没机会」这一段。
        startupRecoveryClaimed = true
        guard isPrimaryInstance, !isTerminating, let intent = preferences.intent else { return }
        guard !isBusy else {
            // 恢复那一刻正忙（R7 D）：被一次检查吞掉的恢复会让运行时一直被我们停着、容器不拉、不发通知——记下来，操作结束后补做。
            if intent.hasObligation { deferredRecoveryNonce = intent.nonce }
            return
        }
        deferredRecoveryNonce = nil
        let op = beginOperation(.recovering)
        task = Task {
            await self.runRecovery(intent, op: op)
            self.operationEnded()
        }
    }

    /// App 退出前调用：运行时可能被我们停着的阶段要等它走完；其余阶段取消后立即放行
    /// （已弹出的密码框留给系统：授权后 root 会因运行时仍在跑而 stop-timeout，什么都不装）。
    /// 退出入口的同步置位（附录 C3，与 `prepareForTermination` 第一句同义、只是更早）：
    /// `prepareForTermination` 跑在退出的 Task 里，隔着一次调度——那一段里按钮与通知动作仍可能开新操作。
    public func beginTermination() { isTerminating = true }

    public func prepareForTermination() async {
        isTerminating = true
        if isInCommittedPhase {
            await task?.value
        } else {
            // 非 committed 的在途任务一律取消——包括不置 busy 的确认任务（`runtimeMayHaveRestarted`，R6）：只看 isBusy 会漏掉它。
            task?.cancel()
        }
    }

    /// 测试用：等当前操作走完。
    func awaitOperationForTests() async {
        while let current = task {
            await current.value
            if task == current { break }
        }
    }

    // MARK: - 检查流程

    private func startCheck(_ trigger: UpdateTrigger) {
        guard isPrimaryInstance, !isTerminating else { return }
        if state == .checking {
            if trigger == .manual { manualRequested = true }
            return
        }
        guard !isBusy else { return }
        let op = beginOperation(.checking)
        manualRequested = trigger == .manual
        task = Task {
            await self.runCheck(op: op)
            self.operationEnded()
        }
    }

    private func runCheck(op: Int) async {
        let installedResult = await environment.commands.installedVersion()
        // 检查不算 committed，退出会取消我们：之后什么都不写、不再往下走（R7）。
        guard !Task.isCancelled else { return }
        let installed: RuntimeVersion
        switch installedResult {
        case .notInstalled:
            apply(op) { self.state = .notInstalled }
            return
        case .unknown(let reason):
            apply(op) { self.state = .checkFailed(.installedVersionUnknown(reason)) }
            return
        case .installed(let version):
            guard apply(op, { self.lastKnownInstalled = version }) else { return }
            installed = version
        }

        if let until = preferences.rateLimitedUntil, environment.now() < until {
            apply(op) { self.state = .checkFailed(.rateLimited(until: until)) }
            return
        }

        let result = await environment.feed.latestRelease(now: environment.now())
        // 请求可能不理会取消、照常返回（R7）：退出之后不写偏好、不改状态，手动检查也不再往升级里走。
        guard op == operation, !Task.isCancelled else { return }

        switch result {
        case .rateLimited(let until):
            preferences.rateLimitedUntil = until
            state = .checkFailed(.rateLimited(until: until))
        case .failed(let failure):
            state = .checkFailed(.release(failure))
        case .release(let release):
            preferences.lastSuccessfulCheck = environment.now()
            preferences.rateLimitedUntil = nil
            let trigger: UpdateTrigger = manualRequested ? .manual : .automatic
            switch UpdatePolicy.decide(installed: installed, latest: release, skipped: preferences.skippedVersion, trigger: trigger) {
            case .upToDate(let version):
                state = .upToDate(version)
            case .skipped(let installed, let release):
                state = .skipped(installed: installed, release: release)
            case .available(let installed, let release):
                if trigger == .manual {
                    setState(.updating(release, .downloading))
                    await runInstall(release, from: installed, op: op)
                } else {
                    state = .available(installed: installed, release: release)
                    onUpdateAvailable?(release, installed)
                }
            }
        }
    }

    // MARK: - 共用

    /// 开始一个新操作：号 +1，同步写入起始状态——单飞判断与状态切换之间不跨 await。
    func beginOperation(_ initial: State) -> Int {
        operation += 1
        setState(initial)
        return operation
    }

    func setState(_ newState: State) {
        state = newState
        stageStartedAt = environment.now()
    }

    /// 升级进行中切换阶段（其余状态下是 no-op：恢复 / 手动启动路径复用同一套复原代码）。
    func setStage(_ stage: UpdateStage, op: Int) {
        guard op == operation, case .updating(let release, _) = state else { return }
        setState(.updating(release, stage))
    }

    /// 号对得上才写。返回是否写了。
    @discardableResult
    func apply(_ op: Int, _ body: () -> Void) -> Bool {
        guard op == operation else { return false }
        body()
        return true
    }
}

/// 升级进行到哪一步。前三步运行时未动（可安全取消 / 退出）；后四步运行时可能被我们停着。
public enum UpdateStage: Sendable, Equatable {
    case downloading
    case verifying
    case awaitingAuthorization
    case stoppingRuntime
    case installing
    case startingRuntime
    case restoringContainers
    /// 附录 C4：停机前读不到在跑容器 ⇒ 没停任何东西，只等 root 放弃（最长 wait 秒数）。非 committed：退出可立即放行。
    case abandoning

    public var isCommitted: Bool {
        switch self {
        case .downloading, .verifying, .awaitingAuthorization, .abandoning: false
        case .stoppingRuntime, .installing, .startingRuntime, .restoringContainers: true
        }
    }
}

public enum CheckFailure: Sendable, Equatable {
    case installedVersionUnknown(String)
    case rateLimited(until: Date)
    case release(ReleaseCheckFailure)
}

/// 升级 / 恢复结束时还没复原的东西（R4 B/C/D/E）。只负责**如实说明**；「启动运行时」按钮跟着义务走（`canStartRuntime`）。
public enum PendingRestore: Sendable, Equatable {
    /// 运行时被我们停着、没起回来。`because` ∈ `.anotherJobRunning`（锁被别的 root 任务持着，或本次 root 任务可能还没结束）/
    /// `.lockProbeFailed` / `.startFailed`。
    case runtimeStopped(because: UpdateFailure)
    /// 运行时在跑，但升级前在跑的这些容器还没拉回来。**非空**（空 = 什么都不欠 = 义务已清，不留 pending）。
    case containersNotRestarted([ContainerID])
}

/// 手动复原按钮做的是什么（两者都调 `startRuntime()`，行为相同，只是标题说的目标不同）。
public enum ManualRestore: Sendable, Equatable {
    /// 欠「起运行时」：起运行时，再拉升级前在跑的容器。
    case startRuntime
    /// 「起运行时」已解除，只欠会话内的容器（R4 E）。
    case startRemainingContainers
}

public enum UpdateFailure: Sendable, Equatable {
    case anotherJobRunning
    case lockProbeFailed(Int32)
    /// 新版本装上了（实读版本 = 目标），只是运行时 / 容器还没复原（R4 B：不能读成「更新失败」）。原因在 `PendingRestore` 里。
    case installedButNotRestarted(RuntimeVersion)
    case download(DownloadFailure)
    /// user 侧校验（digest / 签名）——在弹密码框之前。
    case verification(PackageVerification)
    /// root 侧复验或参数 / 源文件检查——在 ready 之前。
    case rootVerification(PrivilegedJobResult)
    case stopTimedOut(blockers: [String])
    case installFailed(details: [String])
    /// 装后复查证明不了没有混跑（`blockers` = 映射着本包文件的进程，或 `lsof-failed`）。
    case racedDuringInstall(blockers: [String])
    case versionMismatch(installed: InstalledRuntime)
    case startFailed(CommandOutcome)
    case unknown(String)
    /// 恢复时发现上一次在安装前被打断或意外失败。
    case interrupted
    /// 附录 C4：停机前读不到在跑容器（`ls` 失败）⇒ 没停运行时、没装。
    case snapshotUnavailable
}
