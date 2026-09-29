import Foundation

/// 本机装的 apple/container 是哪个版本。**三种「没有」不折叠**（Plan §4）。
public enum InstalledRuntime: Sendable, Equatable {
    /// `/usr/local/bin/container` 不存在（本功能不代装）。
    case notInstalled
    /// 二进制在，但读不出版本（非 0 退出、输出读不懂、超时）。**不是**「已是最新」。
    case unknown(String)
    case installed(RuntimeVersion)
}

/// 一条 CLI 命令的结局。
public enum CommandOutcome: Sendable, Equatable {
    case succeeded
    /// `detail` = stderr 末尾若干行（诊断用，原样透传）。
    case failed(exitCode: Int32, detail: String)
    case timedOut
    case notInstalled
}

/// root 升级任务此刻在不在跑（AD4：看 `lockf` 锁有没有被持有）。
public enum PrivilegedJobState: Sendable, Equatable {
    case idle
    case running
    /// 探测本身失败（锁文件打不开等）。**不当成空闲**：调用方据此拒绝「启动运行时」这类需要锁空闲的动作。
    case probeFailed(Int32)
}

/// 升级链路用到的全部命令（Day 22 T4）。**全走 CLI，不经 XPC**（AD1：升级器是修「XPC 说不通」的工具，
/// 不能依赖那条可能已经坏掉的通道）。可执行路径写死、参数走数组（`ProcessRunner`）。
public struct RuntimeCommands: Sendable {

    public static let cliPath = "/usr/local/bin/container"
    /// root 升级任务的全局锁（root 脚本以 fd 形式持有，F19 / F23）。
    /// 与 root 脚本的 `LOCK` 同一处（目录由脚本常量派生，改一边另一边跟着变）。父目录在第一次升级之前不存在——
    /// `lockf -n` 此时退出 69，照样映射为空闲。
    public static let lockPath = "\(PrivilegedInstallScript.stateDirectory)/cof-runtime-update.lock"
    static let lockfPath = "/usr/bin/lockf"

    static let versionTimeout: Duration = .seconds(15)
    /// 上游 stop：每容器 5 秒 + 最多 20 秒 shutdown（F9）；120 秒 < root 等停机的 300 秒（Plan §5.3 的乘法）。
    static let stopTimeout: Duration = .seconds(120)
    /// 首次 start 可能顺带拉 vminit 镜像（F8）。
    static let startTimeout: Duration = .seconds(300)
    static let listTimeout: Duration = .seconds(30)
    static let containerStartTimeout: Duration = .seconds(120)
    static let lockProbeTimeout: Duration = .seconds(10)
    /// stderr 末尾保留几行作诊断。
    static let detailLines = 5

    private let runner: any ProcessRunning
    private let prober: any RuntimeProber
    private let lockPath: String

    public init(runner: any ProcessRunning = ProcessRunner(), prober: any RuntimeProber = ApiserverProber()) {
        self.init(runner: runner, prober: prober, lockPath: Self.lockPath)
    }

    /// 锁路径只在测试里换成临时文件。
    init(runner: any ProcessRunning, prober: any RuntimeProber, lockPath: String) {
        self.runner = runner
        self.prober = prober
        self.lockPath = lockPath
    }

    // MARK: - 版本

    public func installedVersion() async -> InstalledRuntime {
        let result: ProcessResult
        do {
            result = try await runner.run(Self.cliPath, arguments: ["--version"], timeout: Self.versionTimeout)
        } catch .notFound {
            return .notInstalled
        } catch {
            return .unknown(String(describing: error))
        }

        guard result.exitCode == 0 else { return .unknown("exit \(result.exitCode): \(Self.tail(result.stderr))") }
        guard let version = Self.parseVersion(result.stdout) else { return .unknown(Self.tail(result.stdout)) }
        return .installed(version)
    }

    /// `container CLI version 1.4.1 (build: release, commit: 9a8917c)` → 1.4.1。
    /// 取 `version` 之后的那个词——上游自己的 `update-container.sh` 也按这个位置取（`awk '{print $4}'`）。
    static func parseVersion(_ output: String) -> RuntimeVersion? {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard let index = words.firstIndex(of: "version"), index + 1 < words.count else { return nil }
        return RuntimeVersion(parsing: String(words[index + 1]))
    }

    // MARK: - 运行时起停

    public func stopRuntime() async -> CommandOutcome {
        await outcome(of: ["system", "stop"], timeout: Self.stopTimeout)
    }

    /// `--enable-kernel-install`：内核缺失时上游会交互提问、stdin 读不到就抛错（F8）；这是那个提问的默认答案。
    public func startRuntime() async -> CommandOutcome {
        await outcome(of: ["system", "start", "--enable-kernel-install"], timeout: Self.startTimeout)
    }

    /// 运行时自动启动用（Day 23）。显式 `--timeout`：上游注册 apiserver 后 ping 它、不通即非 0 退出（`SystemStart.swift`），
    /// 等多久不吃上游默认值（CLAUDE.md）。内核：登录时的自动路径不装（`--disable-kernel-install`），用户点按钮才装。
    public func startRuntime(allowKernelInstall: Bool) async -> CommandOutcome {
        let kernel = allowKernelInstall ? "--enable-kernel-install" : "--disable-kernel-install"
        let arguments = ["system", "start", "--timeout", String(Self.apiserverReadyTimeoutSeconds), kernel]
        return await outcome(of: arguments, timeout: Self.startTimeout)
    }

    /// 上游等 apiserver 响应的时限（与上游默认 `XPCClient.xpcRegistrationTimeout` 同值，显式传）。外层仍有 `startTimeout`。
    static let apiserverReadyTimeoutSeconds = 60

    /// 以真实可执行路径判断 apiserver 在不在（复用 supervisor 的 libproc prober，argv[0] 骗不过它）。
    public func isRuntimeRunning() async -> Bool {
        if case .running = await prober.probe() { return true }
        return false
    }

    // MARK: - 容器快照与恢复（AD6）

    /// 此刻在跑的容器（`ls --quiet` 只列在跑的，一行一个 ID）。失败 ≠「没有容器在跑」。
    public func runningContainerIDs() async -> Result<[ContainerID], CommandFailure> {
        let result: ProcessResult
        do {
            result = try await runner.run(Self.cliPath, arguments: ["ls", "--quiet"], timeout: Self.listTimeout)
        } catch {
            return .failure(CommandFailure(String(describing: error)))
        }
        guard result.exitCode == 0 else {
            return .failure(CommandFailure("exit \(result.exitCode): \(Self.tail(result.stderr))"))
        }
        return .success(result.stdout.split(whereSeparator: \.isNewline).compactMap { ContainerID(String($0)) })
    }

    /// `--` 截断选项解析：以 `-` 开头的 ID 也只会被当作位置参数（实测 `container start -- -h`）。
    public func startContainer(_ id: ContainerID) async -> CommandOutcome {
        await outcome(of: ["start", "--", id.rawValue], timeout: Self.containerStartTimeout)
    }

    // MARK: - root 任务锁（AD4）

    /// `lockf -s -k -n -t 0 <lock> /usr/bin/true`：`-n` 文件不存在时不创建（用户也建不了 `/var/run` 下的文件），
    /// `-k` 不删锁文件，`-t 0` 抢不到立刻返回。持锁只有一瞬间、只跑 `/usr/bin/true`，无副作用。
    public func privilegedJobState() async -> PrivilegedJobState {
        let arguments = ["-s", "-k", "-n", "-t", "0", lockPath, "/usr/bin/true"]
        do {
            let result = try await runner.run(Self.lockfPath, arguments: arguments, timeout: Self.lockProbeTimeout)
            switch result.exitCode {
            case 0, 69: return .idle        // 69 = EX_UNAVAILABLE：锁文件不存在（从未跑过，或重启后被清）
            case 75: return .running        // 75 = EX_TEMPFAIL：被别人持有
            default: return .probeFailed(result.exitCode)
            }
        } catch {
            return .probeFailed(-1)
        }
    }

    // MARK: - 共用

    private func outcome(of arguments: [String], timeout: Duration) async -> CommandOutcome {
        do {
            let result = try await runner.run(Self.cliPath, arguments: arguments, timeout: timeout)
            return result.exitCode == 0
                ? .succeeded
                : .failed(exitCode: result.exitCode, detail: Self.tail(result.stderr))
        } catch .notFound {
            return .notInstalled
        } catch .timedOut {
            return .timedOut
        } catch {
            return .failed(exitCode: -1, detail: String(describing: error))
        }
    }

    static func tail(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).suffix(detailLines).joined(separator: "\n")
    }
}

/// 读取类命令的失败（诊断文本原样透传，不翻译——Day 14 §1：技术详情保持可搜索）。
public struct CommandFailure: Error, Equatable, Sendable {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
}
