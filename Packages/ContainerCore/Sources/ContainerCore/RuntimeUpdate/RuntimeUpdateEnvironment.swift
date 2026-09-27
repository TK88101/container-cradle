import Foundation

/// 升级链路用到的 CLI 能力（`RuntimeCommands` 的协议面，测试注入 fake）。
public protocol RuntimeCommanding: Sendable {
    func installedVersion() async -> InstalledRuntime
    func stopRuntime() async -> CommandOutcome
    func startRuntime() async -> CommandOutcome
    func isRuntimeRunning() async -> Bool
    func runningContainerIDs() async -> Result<[ContainerID], CommandFailure>
    func startContainer(_ id: ContainerID) async -> CommandOutcome
    func privilegedJobState() async -> PrivilegedJobState
}

extension RuntimeCommands: RuntimeCommanding {}

/// 崩溃恢复用的意图记录（AD9）。App 起 osascript 时写下，`stopIssued` 在 stop **之前**置真。
/// 下次启动若还在，说明上一次升级没有走完收尾——据它与 root 状态文件决定要不要复原。
public struct UpdateIntent: Sendable, Equatable, Codable {
    public let nonce: UUID
    public let target: RuntimeVersion
    public let from: RuntimeVersion
    public var runtimeWasRunning: Bool
    public var stopIssued: Bool
    /// 停机前在跑的容器（AD6：升级后要拉回的全集）。
    public var runningContainerIDs: [ContainerID]
    /// 停机那一刻冻结的「已启用白名单」——这些归 supervisor 拉，升级器不碰（避免两个启动者抢同一个容器）。
    public var managedContainerIDs: [ContainerID]
    /// 「起运行时」这一半义务已解除：我们 stop 之后观测到运行时在跑（别处 / 用户把它起来了）（R4 E）。
    /// 剩下的只是「拉容器」——它只在运行时在跑时执行、永不为它起运行时，且**只活在本次会话**（`recordIntent` 不落盘）。
    public var startDischarged: Bool

    public init(
        nonce: UUID,
        target: RuntimeVersion,
        from: RuntimeVersion,
        runtimeWasRunning: Bool = false,
        stopIssued: Bool = false,
        runningContainerIDs: [ContainerID] = [],
        managedContainerIDs: [ContainerID] = [],
        startDischarged: Bool = false
    ) {
        self.nonce = nonce
        self.target = target
        self.from = from
        self.runtimeWasRunning = runtimeWasRunning
        self.stopIssued = stopIssued
        self.runningContainerIDs = runningContainerIDs
        self.managedContainerIDs = managedContainerIDs
        self.startDischarged = startDischarged
    }

    /// 有一份复原义务：我们停过一个在跑的运行时，还没复原完（「启动运行时」按钮跟着它走，R2 E）。
    public var hasObligation: Bool { stopIssued && runtimeWasRunning }

    /// 欠一次「起运行时」：我们停的，且那次 stop 之后没见它跑过（R4 E：只为撤销自己的 stop 去起运行时）。
    public var owesRuntimeStart: Bool { hasObligation && !startDischarged }

    private enum CodingKeys: String, CodingKey {
        case nonce, target, from, runtimeWasRunning, stopIssued, runningContainerIDs, managedContainerIDs, startDischarged
    }

    /// 旧记录没有 `startDischarged` 键 ⇒ 按 false 读（解码失败 = 记录读成 nil = 复原义务静默丢失）。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nonce = try values.decode(UUID.self, forKey: .nonce)
        target = try values.decode(RuntimeVersion.self, forKey: .target)
        from = try values.decode(RuntimeVersion.self, forKey: .from)
        runtimeWasRunning = try values.decode(Bool.self, forKey: .runtimeWasRunning)
        stopIssued = try values.decode(Bool.self, forKey: .stopIssued)
        runningContainerIDs = try values.decode([ContainerID].self, forKey: .runningContainerIDs)
        managedContainerIDs = try values.decode([ContainerID].self, forKey: .managedContainerIDs)
        startDischarged = try values.decodeIfPresent(Bool.self, forKey: .startDischarged) ?? false
    }
}

/// 更新器的持久偏好。跳过的版本是**偏好**不是配置资产（白名单存 JSON 的理由——用户手改、Finder 可见——对它不成立），
/// 故用 `UserDefaults`。只在 MainActor 上读写。
@MainActor
public protocol UpdatePreferences: AnyObject {
    var skippedVersion: RuntimeVersion? { get set }
    var lastSuccessfulCheck: Date? { get set }
    var rateLimitedUntil: Date? { get set }
    var intent: UpdateIntent? { get set }
    /// D4：「自动检查更新」开关，默认开。关掉只停自动检查，手动按钮照常。
    var isAutomaticCheckEnabled: Bool { get set }
}

@MainActor
public final class UserDefaultsUpdatePreferences: UpdatePreferences {

    private let defaults: UserDefaults

    enum Key {
        static let skipped = "runtimeUpdate.skippedVersion"
        static let lastCheck = "runtimeUpdate.lastSuccessfulCheck"
        static let rateLimited = "runtimeUpdate.rateLimitedUntil"
        static let intent = "runtimeUpdate.intent"
        static let autoCheck = "runtimeUpdate.automaticCheckEnabled"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var skippedVersion: RuntimeVersion? {
        get { defaults.string(forKey: Key.skipped).flatMap(RuntimeVersion.init(parsing:)) }
        set { defaults.set(newValue?.description, forKey: Key.skipped) }
    }

    public var lastSuccessfulCheck: Date? {
        get { defaults.object(forKey: Key.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastCheck) }
    }

    public var rateLimitedUntil: Date? {
        get { defaults.object(forKey: Key.rateLimited) as? Date }
        set { defaults.set(newValue, forKey: Key.rateLimited) }
    }

    /// 整条记录编码成一个值写入——单键原子，不会出现「nonce 写了、stopIssued 没写」的半截状态。
    public var intent: UpdateIntent? {
        get { defaults.data(forKey: Key.intent).flatMap { try? JSONDecoder().decode(UpdateIntent.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.intent) }
    }

    public var isAutomaticCheckEnabled: Bool {
        get { defaults.object(forKey: Key.autoCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoCheck) }
    }
}

/// store 的全部外部依赖。生产装配在 app 的 composition root；测试逐项换 fake。
public struct RuntimeUpdateEnvironment: Sendable {
    public var feed: any ReleaseFeeding
    public var downloader: any PackageDownloading
    public var verifier: any PackageVerifying
    public var installer: any PrivilegedInstalling
    public var commands: any RuntimeCommanding
    public var now: @Sendable () -> Date
    /// 恢复流程等 root 任务结束时的轮询用（复用 supervisor 的时钟抽象，测试注入立即返回的时钟）。
    public var clock: any SupervisorClock
    /// 此刻「已启用的白名单」——停机那一刻冻结进意图记录（AD6）。
    public var managedContainerIDs: @MainActor @Sendable () async -> Set<ContainerID>
    /// 请 supervisor 立即 reconcile 白名单（恢复 / 手动启动路径用：App 冷启动时 supervisor 走 baseline，不会自己拉）。
    /// 返回 = 请求已被 supervisor 接受（生产上先排空白名单写入链，再 `Supervisor.reconcileManagedNow()`：先探一次、再同步投递强制请求）。
    public var requestManagedReconcile: @MainActor @Sendable () async -> Void
    /// 上面那次请求最多等多久（R4 G/F：它在 committed 段里，而白名单写入链可能卡在文件系统上——退出不许被它冻住）。
    public var reconcileRequestLimit: Duration
    /// 系统密码框里的说明文字（本地化住 Presentation）。
    public var authorizationPrompt: @Sendable (_ from: RuntimeVersion, _ to: RuntimeVersion) -> String
    /// root 级动作的日志（安全评审 L10）。
    public var log: any RuntimeUpdateLog

    public init(
        feed: any ReleaseFeeding = GitHubReleaseFeed(),
        downloader: any PackageDownloading = PackageDownloader(),
        verifier: any PackageVerifying = PackageVerifier(),
        installer: any PrivilegedInstalling = PrivilegedInstaller(),
        commands: any RuntimeCommanding = RuntimeCommands(),
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any SupervisorClock = SystemSupervisorClock(),
        log: any RuntimeUpdateLog = OSLogRuntimeUpdateLog(),
        managedContainerIDs: @escaping @MainActor @Sendable () async -> Set<ContainerID>,
        requestManagedReconcile: @escaping @MainActor @Sendable () async -> Void,
        reconcileRequestLimit: Duration = .seconds(30),
        authorizationPrompt: @escaping @Sendable (RuntimeVersion, RuntimeVersion) -> String
    ) {
        self.feed = feed
        self.downloader = downloader
        self.verifier = verifier
        self.installer = installer
        self.commands = commands
        self.now = now
        self.clock = clock
        self.log = log
        self.managedContainerIDs = managedContainerIDs
        self.requestManagedReconcile = requestManagedReconcile
        self.reconcileRequestLimit = reconcileRequestLimit
        self.authorizationPrompt = authorizationPrompt
    }
}
