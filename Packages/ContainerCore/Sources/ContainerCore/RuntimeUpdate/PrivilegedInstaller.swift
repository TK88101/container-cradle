import Darwin
import Foundation
import Synchronization

/// 提权安装的抽象——store 只认它，测试注入 fake。
public protocol PrivilegedInstalling: Sendable {

    /// 起 root 任务。root 通过授权、复验通过后会写本 nonce 的状态文件——**只有看到它，才调用一次 `onReady`**
    /// （store 在里面记快照、写意图记录、stop 运行时）。然后等 root 任务结束，结果只按 root 的输出判定（AD8）。
    /// `version`：要装的版本——root 在签名通过后核对包的 PackageInfo（identifier + version），不符即 `unexpected-version`（安全评审 M2）。
    func run(
        package: URL,
        digest: SHA256Digest,
        version: RuntimeVersion,
        nonce: UUID,
        prompt: String,
        onReady: @escaping @Sendable () async -> Void
    ) async -> PrivilegedJobOutcome

    /// 读某个 nonce 的状态文件（崩溃恢复用，AD9）。
    func readStateFile(nonce: UUID) -> PrivilegedJobStateFile?
}

/// 真的提权安装（Day 22 T5）：`/usr/bin/osascript` + `do shell script … with administrator privileges`。
///
/// ## 先授权，后停机（AD3）
///
/// 这里**不**决定何时停运行时，只负责把「root 已授权且复验通过」这件事（状态文件出现）如实转告一次。
/// 密码框取消 / 复验失败时状态文件根本不会出现 ⇒ `onReady` 不会被调用 ⇒ 运行时一秒都没停（A5）。
///
/// ## 不设超时（Plan §5.3）
///
/// 授权前等多久由用户掌控；授权后受 root 自己的等待上限（300 秒）+ installer 时长约束。
/// App 对 osascript 设超时只会制造「App 放手了、root 还在装」的窗口（codex 第 1 轮 C2）。
public struct PrivilegedInstaller: PrivilegedInstalling {

    static let osascriptPath = "/usr/bin/osascript"
    static let pollInterval: Duration = .milliseconds(250)

    private let runner: any ProcessRunning
    private let stateDirectory: String
    private let waitSeconds: Int

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.init(
            runner: runner,
            stateDirectory: PrivilegedInstallScript.stateDirectory,
            waitSeconds: PrivilegedInstallScript.productionWaitSeconds
        )
    }

    /// 状态目录只在测试里换成临时目录（root 脚本那边写死 `PrivilegedInstallScript.stateDirectory`）。
    init(runner: any ProcessRunning, stateDirectory: String, waitSeconds: Int) {
        self.runner = runner
        self.stateDirectory = stateDirectory
        self.waitSeconds = waitSeconds
    }

    public func run(
        package: URL,
        digest: SHA256Digest,
        version: RuntimeVersion,
        nonce: UUID,
        prompt: String,
        onReady: @escaping @Sendable () async -> Void
    ) async -> PrivilegedJobOutcome {
        let arguments = PrivilegedInstallScript.osascriptArguments(
            packagePath: package.path, digest: digest, ownerUID: getuid(),
            nonce: nonce, waitSeconds: waitSeconds, target: version, prompt: prompt
        )

        let finished = Mutex(false)
        let job = Task { [runner] () -> PrivilegedJobOutcome in
            defer { finished.withLock { $0 = true } }
            do {
                let result = try await runner.run(Self.osascriptPath, arguments: arguments, timeout: nil)
                return PrivilegedInstallScript.outcome(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
            } catch {
                return .unknown(String(describing: error))
            }
        }

        // 轮询本 nonce 的状态文件，直到它出现（→ onReady 一次）或 root 任务先结束（取消 / 复验失败）。
        // 边界：若运行时本来就停着，root 写完 ready 会立刻安装、可能在下一次轮询前就结束——此时 onReady 不会被调用，
        // 这是对的：没有东西可快照、可停（root 只在保护集合无人运行时才会这么快往下走，AD7）。
        while !finished.withLock({ $0 }) {
            // 调用方已放弃（App 在 preparing 阶段退出，store 取消了任务）：不再轮询——被取消的 `Task.sleep` 立即抛错，
            // 否则这里会忙转——更不许随后看到 ready 就 onReady，那会让一个正在退出的 App 停掉运行时（安全评审 L9）。
            // root 任务留给系统：授权后它会因运行时仍在跑而 stop-timeout，什么都不装（§5.4「App 退出」列）。
            if Task.isCancelled { break }
            // 只认 `ready`（codex R1 [P1]）：复验失败的结局不是「已授权且复验通过」，绝不能因此去停运行时。
            // root 侧另有第三层：状态文件路径在写 ready 的前一行才赋值，ready 之前根本写不出状态文件（安全评审 H1）。
            if readStateFile(nonce: nonce) == .ready {
                await onReady()
                break
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return await job.value
    }

    public func readStateFile(nonce: UUID) -> PrivilegedJobStateFile? {
        let path = "\(stateDirectory)/cof-runtime-update.\(nonce.uuidString)"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return PrivilegedInstallScript.parseStateFile(text)
    }
}
