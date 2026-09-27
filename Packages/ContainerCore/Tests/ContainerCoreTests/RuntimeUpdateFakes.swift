import Foundation
import Synchronization

@testable import ContainerCore

/// 所有 fake 共用的事件日志——T7 的很多断言是**顺序**断言（先 X 后 Y）。
final class EventLog: @unchecked Sendable {
    private let events = Mutex<[String]>([])
    func append(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
    func count(_ event: String) -> Int { all.filter { $0 == event }.count }
    func index(of event: String) -> Int? { all.firstIndex(of: event) }
}

@MainActor
final class InMemoryUpdatePreferences: UpdatePreferences {
    var skippedVersion: RuntimeVersion?
    var lastSuccessfulCheck: Date?
    var rateLimitedUntil: Date?
    var intent: UpdateIntent?
    var isAutomaticCheckEnabled = true
}

final class FakeReleaseFeed: ReleaseFeeding, @unchecked Sendable {
    let log: EventLog
    let result = Mutex<ReleaseCheckResult>(.failed(.network("unset")))
    /// 非 nil 时，请求会挂在这里直到测试放行（用来制造「检查进行中」的窗口）。
    let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let gated = Mutex(false)

    init(log: EventLog, _ result: ReleaseCheckResult) {
        self.log = log
        self.result.withLock { $0 = result }
    }

    func latestRelease(now: Date) async -> ReleaseCheckResult {
        log.append("feed")
        if gated.withLock({ $0 }) {
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
        }
        return result.withLock { $0 }
    }

    func release() {
        gated.withLock { $0 = false }
        gate.withLock { $0?.resume(); $0 = nil }
    }
}

final class FakeDownloader: PackageDownloading, @unchecked Sendable {
    let log: EventLog
    let failure: DownloadFailure?
    let directory: URL
    init(log: EventLog, failure: DownloadFailure? = nil) throws {
        self.log = log
        self.failure = failure
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cof-dl-\(UUID().uuidString)")
    }
    /// 下载时、返回之前执行（R7：把取消卡进下载这个 await）。
    let hook = AsyncHook()
    func download(_ release: RuntimeRelease) async throws(DownloadFailure) -> URL {
        log.append("download")
        await hook.run()
        if let failure { throw failure }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(release.packageName)
        FileManager.default.createFile(atPath: file.path, contents: Data("pkg".utf8))
        return file
    }
}

final class FakeVerifier: PackageVerifying, @unchecked Sendable {
    let log: EventLog
    let result: PackageVerification
    init(log: EventLog, _ result: PackageVerification = .ok) {
        self.log = log
        self.result = result
    }
    func verify(_ file: URL, expected: SHA256Digest) async -> PackageVerification {
        log.append("verify")
        return result
    }
}

/// 模拟 root 任务：`callsReady` 时先调用 onReady（= 状态文件出现），再返回脚本化的结局。
final class FakePrivilegedInstaller: PrivilegedInstalling, @unchecked Sendable {
    let log: EventLog
    let callsReady: Bool
    let outcome: PrivilegedJobOutcome
    /// 非空时按次序逐次返回（E：第一次失败、第二次成功），用完回落到 `outcome`。
    let queuedOutcomes = Mutex<[PrivilegedJobOutcome]>([])
    let stateFile = Mutex<PrivilegedJobStateFile?>(nil)
    let prompts = Mutex<[String]>([])
    let versions = Mutex<[RuntimeVersion]>([])
    let afterRun: (@Sendable (PrivilegedJobOutcome) -> Void)?
    /// 授权之后、ready 之前要执行的动作（例如模拟另一个实例清掉 defaults 里的意图记录）。
    let beforeReady = Mutex<(@Sendable () async -> Void)?>(nil)
    /// ready 之后（store 已 stop 运行时）、root 结束之前要执行的动作（例如模拟有人从别处起了运行时）。
    let afterReady = Mutex<(@Sendable () async -> Void)?>(nil)

    init(log: EventLog, callsReady: Bool, outcome: PrivilegedJobOutcome, afterRun: (@Sendable (PrivilegedJobOutcome) -> Void)? = nil) {
        self.log = log
        self.callsReady = callsReady
        self.outcome = outcome
        self.afterRun = afterRun
    }

    func run(package: URL, digest: SHA256Digest, version: RuntimeVersion, nonce: UUID, prompt: String,
             onReady: @escaping @Sendable () async -> Void) async -> PrivilegedJobOutcome {
        log.append("authorize")
        prompts.withLock { $0.append(prompt) }
        versions.withLock { $0.append(version) }
        if let hook = beforeReady.withLock({ $0 }) { await hook() }
        if callsReady {
            log.append("ready")
            await onReady()
            if let hook = afterReady.withLock({ $0 }) { await hook() }
        }
        log.append("root-finished")
        let result = queuedOutcomes.withLock { $0.isEmpty ? outcome : $0.removeFirst() }
        afterRun?(result)
        return result
    }

    func readStateFile(nonce: UUID) -> PrivilegedJobStateFile? { stateFile.withLock { $0 } }
}

/// 可编排的 CLI：运行时是否在跑、有哪些容器在跑、各命令返回什么、锁状态序列。
final class FakeRuntimeCommands: RuntimeCommanding, @unchecked Sendable {
    let log: EventLog
    struct Script {
        var installed: InstalledRuntime = .installed(RuntimeVersion(major: 1, minor: 4, patch: 1))
        var installedAfterInstall: InstalledRuntime?
        var runtimeRunning = true
        var running: [String] = []
        var stop: CommandOutcome = .succeeded
        var start: CommandOutcome = .succeeded
        var containerStart: [String: CommandOutcome] = [:]
        /// 启动失败但随后仍然在跑（被别人拉起了）的容器。
        var runningAfterFailedStart: Set<String> = []
        var lockStates: [PrivilegedJobState] = [.idle]
        /// `ls` 失败（附录 C4：停机前读不到在跑容器 ⇒ fail-closed，不停机）。
        var listFails = false
    }
    let script: Mutex<Script>
    /// stop 被调用那一刻要执行的检查（例如读意图记录）。
    let onStop = Mutex<(@Sendable () async -> Void)?>(nil)
    /// system start 被调用那一刻要执行的检查（例如断言此刻算 committed）。
    let onStartRuntime = Mutex<(@Sendable () async -> Void)?>(nil)
    /// 第 n 次探锁时、返回之前要执行的动作（R3：把取消卡进「探锁的 await」这个窗口）。
    let onLockProbe = Mutex<(@Sendable (Int) async -> Void)?>(nil)
    let lockProbeCount = Mutex(0)
    /// 第 n 次问「运行时在不在跑」/ 第 n 次 `ls` 时、返回之前要执行的动作（R4：把取消 / 新操作卡进这两个 await）。
    let onIsRunning = Mutex<(@Sendable (Int) async -> Void)?>(nil)
    let onList = Mutex<(@Sendable (Int) async -> Void)?>(nil)
    /// 读已装版本时、返回之前执行的动作（R6：把取消卡进恢复收尾那次读版本）。
    let onVersion = Mutex<(@Sendable () async -> Void)?>(nil)
    private let isRunningCount = Mutex(0)
    private let listCount = Mutex(0)
    private let installed = Mutex(false)

    init(log: EventLog, _ script: Script = Script()) {
        self.log = log
        self.script = Mutex(script)
    }

    func markInstalled() { installed.withLock { $0 = true } }

    func installedVersion() async -> InstalledRuntime {
        if let hook = onVersion.withLock({ $0 }) { await hook() }
        log.append("version")
        return script.withLock { s in installed.withLock { $0 } ? (s.installedAfterInstall ?? s.installed) : s.installed }
    }
    func stopRuntime() async -> CommandOutcome {
        if let check = onStop.withLock({ $0 }) { await check() }
        log.append("stop")
        return script.withLock { s in
            if s.stop == .succeeded { s.runtimeRunning = false; s.running = [] }
            return s.stop
        }
    }
    func startRuntime() async -> CommandOutcome {
        if let check = onStartRuntime.withLock({ $0 }) { await check() }
        log.append("start-runtime")
        return script.withLock { s in
            if s.start == .succeeded { s.runtimeRunning = true }
            return s.start
        }
    }
    func isRuntimeRunning() async -> Bool {
        let n = isRunningCount.withLock { $0 += 1; return $0 }
        if let hook = onIsRunning.withLock({ $0 }) { await hook(n) }
        log.append("is-running")
        return script.withLock { $0.runtimeRunning }
    }
    func runningContainerIDs() async -> Result<[ContainerID], CommandFailure> {
        let n = listCount.withLock { $0 += 1; return $0 }
        if let hook = onList.withLock({ $0 }) { await hook(n) }
        log.append("ls")
        if script.withLock({ $0.listFails }) { return .failure(CommandFailure("ls failed")) }
        return .success(script.withLock { $0.running.compactMap(ContainerID.init) })
    }
    func startContainer(_ id: ContainerID) async -> CommandOutcome {
        log.append("start:\(id.rawValue)")
        return script.withLock { s in
            let outcome = s.containerStart[id.rawValue] ?? .succeeded
            if outcome == .succeeded || s.runningAfterFailedStart.contains(id.rawValue) { s.running.append(id.rawValue) }
            return outcome
        }
    }
    func privilegedJobState() async -> PrivilegedJobState {
        let n = lockProbeCount.withLock { $0 += 1; return $0 }
        if let hook = onLockProbe.withLock({ $0 }) { await hook(n) }
        log.append("lock")
        return script.withLock { s in
            let state = s.lockStates.first ?? .idle
            if s.lockStates.count > 1 { s.lockStates.removeFirst() }
            return state
        }
    }
}

/// 记下每一条 root 级日志（安全评审 L10）。事件按发生顺序，带 nonce 以便断言「同一次操作」。
final class SpyRuntimeUpdateLog: RuntimeUpdateLog, @unchecked Sendable {
    enum Event: Equatable {
        case started(nonce: UUID, target: RuntimeVersion, from: RuntimeVersion, digest: SHA256Digest)
        case ready(nonce: UUID, runtimeWasRunning: Bool, stopIssued: Bool, runningContainers: Int)
        case finished(nonce: UUID, outcome: PrivilegedJobOutcome)
        case restored(nonce: UUID, leftStopped: Bool, hold: RestoreHold, startOutcome: CommandOutcome?, unrestoredContainers: Int)
        case recovering(nonce: UUID, stopIssued: Bool, stateFile: PrivilegedJobStateFile?)
        case snapshotUnavailable(nonce: UUID)
    }
    private let recorded = Mutex<[Event]>([])
    var events: [Event] { recorded.withLock { $0 } }

    func jobStarted(nonce: UUID, target: RuntimeVersion, from: RuntimeVersion, digest: SHA256Digest) {
        recorded.withLock { $0.append(.started(nonce: nonce, target: target, from: from, digest: digest)) }
    }
    func jobReady(nonce: UUID, runtimeWasRunning: Bool, stopIssued: Bool, runningContainers: Int) {
        recorded.withLock { $0.append(.ready(nonce: nonce, runtimeWasRunning: runtimeWasRunning, stopIssued: stopIssued, runningContainers: runningContainers)) }
    }
    func jobFinished(nonce: UUID, outcome: PrivilegedJobOutcome) {
        recorded.withLock { $0.append(.finished(nonce: nonce, outcome: outcome)) }
    }
    func restored(nonce: UUID, leftStopped: Bool, hold: RestoreHold, startOutcome: CommandOutcome?, unrestoredContainers: Int) {
        recorded.withLock { $0.append(.restored(nonce: nonce, leftStopped: leftStopped, hold: hold, startOutcome: startOutcome, unrestoredContainers: unrestoredContainers)) }
    }
    func recovering(nonce: UUID, stopIssued: Bool, stateFile: PrivilegedJobStateFile?) {
        recorded.withLock { $0.append(.recovering(nonce: nonce, stopIssued: stopIssued, stateFile: stateFile)) }
    }
    func snapshotUnavailable(nonce: UUID) {
        recorded.withLock { $0.append(.snapshotUnavailable(nonce: nonce)) }
    }
}

/// 可在测试中途装上的异步钩子（R4 G：把退出卡进「请 reconcile 还在路上」这个窗口）。
final class AsyncHook: @unchecked Sendable {
    private let body = Mutex<(@Sendable () async -> Void)?>(nil)
    func set(_ hook: @escaping @Sendable () async -> Void) { body.withLock { $0 = hook } }
    func run() async {
        if let hook = body.withLock({ $0 }) { await hook() }
    }
}

extension Process {
    /// 测试里等子进程结束。**不用 `waitUntilExit()`**：它在协作线程上同步等 run loop 送达终止通知，而协作线程不跑 run loop——
    /// 实测（Day 22 R4，`RuntimeCommandsTests.realLockfStates`）子进程早已退出它却永不返回，占住协作线程把整个测试进程饿死。
    /// 轮询 `isRunning`（它不靠 run loop 更新）有界、可靠。
    func waitUntilExitWithoutRunLoop() {
        while isRunning { usleep(10_000) }
    }
}

/// 睡眠立即返回的时钟（store 的轮询在测试里不真等）。
struct ImmediateClock: SupervisorClock {
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(until deadline: Date) async { await Task.yield() }
}
