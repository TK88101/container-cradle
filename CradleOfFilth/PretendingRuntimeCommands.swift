#if DEBUG
import ContainerCore
import Synchronization

/// **DEBUG 专用**的 E2E 测试缝（Plan §7 / T13）：启动参数 `-COFUpdatePretendInstalledVersion 1.3.1`
/// 让「决策」以为本机装的是旧版本，于是去「升级」到 latest——实际是**同版本重装**，走满真实链路、零数据格式风险。
///
/// 只骗决策：一旦发出 stop（升级已提交），之后的版本读数全部用真值，收尾的「版本对不对」照常是真判定。
/// Release 构建里这个类型根本不存在（`#if DEBUG`）。
final class PretendingRuntimeCommands: RuntimeCommanding, @unchecked Sendable {

    private let base: any RuntimeCommanding
    private let pretend: RuntimeVersion?
    /// `-COFUpdateFailRunningList YES`：`ls` 一律失败（附录 C4 真机验收：停机前读不到在跑容器 ⇒ 不停机）。
    private let failRunningList: Bool
    private let active = Mutex(true)

    init(base: any RuntimeCommanding, pretend: RuntimeVersion?, failRunningList: Bool = false) {
        self.base = base
        self.pretend = pretend
        self.failRunningList = failRunningList
    }

    func installedVersion() async -> InstalledRuntime {
        if let pretend, active.withLock({ $0 }) { return .installed(pretend) }
        return await base.installedVersion()
    }

    func stopRuntime() async -> CommandOutcome {
        active.withLock { $0 = false }
        return await base.stopRuntime()
    }

    func startRuntime() async -> CommandOutcome { await base.startRuntime() }
    func isRuntimeRunning() async -> Bool { await base.isRuntimeRunning() }
    func runningContainerIDs() async -> Result<[ContainerID], CommandFailure> {
        if failRunningList { return .failure(CommandFailure("COFUpdateFailRunningList")) }
        return await base.runningContainerIDs()
    }
    func startContainer(_ id: ContainerID) async -> CommandOutcome { await base.startContainer(id) }
    func privilegedJobState() async -> PrivilegedJobState { await base.privilegedJobState() }
}
#endif
