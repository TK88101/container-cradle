import Darwin
import Foundation
import Synchronization

/// 一次子进程运行的结果。被信号杀死时 `exitCode` = 128 + 信号号（与 shell 惯例一致）。
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunError: Error, Equatable, Sendable {
    /// 可执行文件不存在或不可执行（例如本机没装 apple/container）。
    case notFound(String)
    case launchFailed(String)
    /// 到点没退出。**已发 SIGTERM（2 秒后仍在就 SIGKILL），但调用方不等它**。
    case timedOut
}

/// 起子进程的抽象——store / 命令层只认它，测试注入 fake。
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: Duration?) async throws(ProcessRunError) -> ProcessResult
}

public extension ProcessRunning {
    func run(_ executable: String, arguments: [String]) async throws(ProcessRunError) -> ProcessResult {
        try await run(executable, arguments: arguments, timeout: nil)
    }
}

/// 真起子进程（Day 22 T4）。本仓库第一次真正 shell-out，下面每一条都是一个已知的坑：
///
/// - **可执行路径写死、参数走数组**：从不经 shell，参数里的引号 / `$()` / 反引号原样到达；不走 `PATH` 查找（防劫持）。
/// - **env 白名单**：子进程只拿到 `inheritedEnvironmentKeys` + 固定 `PATH` + `LC_ALL=C`，**绝不继承 App 的 env**
///   （PLAN「子进程 env 白名单」）；`LC_ALL=C` 让 `pkgutil` 等工具的输出可按字面解析。
/// - **stdin 接空设备**：读 stdin 的子进程立刻读到 EOF。`codex exec` 缺 `</dev/null` 曾静默死等 7.5 小时（memory）。
/// - **stdout / stderr 并发排空**：只在退出后才读，输出 > 64KB 时子进程写满管道、父进程等它退出 → 死锁。
/// - **超时即杀、且不等**：到点先 resume 调用方，再 SIGTERM，2 秒后仍在就 SIGKILL。
///   `withThrowingTaskGroup` 做不出超时（CLAUDE.md ★）——这里是 continuation + 不等。
/// - **后台孙进程攥着管道时不卡**：进程退出后最多再等 1 秒收尾输出，EOF 不来就拿已收到的部分返回。
public struct ProcessRunner: ProcessRunning {

    /// 从 App 环境里**唯一**允许带给子进程的变量（`container` 要 `HOME` 找自己的 app-support 目录）。
    public static let inheritedEnvironmentKeys = ["HOME", "USER", "LOGNAME", "TMPDIR"]
    static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let drainGrace: Duration = .seconds(1)
    static let killGrace: TimeInterval = 2

    public init() {}

    static func environment(from parent: [String: String]) -> [String: String] {
        var environment = parent.filter { inheritedEnvironmentKeys.contains($0.key) }
        environment["PATH"] = fixedPath
        environment["LC_ALL"] = "C"
        return environment
    }

    public func run(
        _ executable: String,
        arguments: [String],
        timeout: Duration?
    ) async throws(ProcessRunError) -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw .notFound(executable) }

        let box = ProcessBox()
        box.process.executableURL = URL(fileURLWithPath: executable)
        box.process.arguments = arguments
        box.process.environment = Self.environment(from: ProcessInfo.processInfo.environment)
        box.process.standardInput = FileHandle.nullDevice

        let stdout = OutputCollector()
        let stderr = OutputCollector()
        box.process.standardOutput = stdout.pipe
        box.process.standardError = stderr.pipe

        switch await Self.launch(box, timeout: timeout) {
        case .launchFailed(let message):
            stdout.stop()
            stderr.stop()
            throw .launchFailed(message)
        case .timedOut:
            throw .timedOut
        case .exited(let code):
            await Self.drain([stdout, stderr])
            return ProcessResult(exitCode: code, stdout: stdout.text, stderr: stderr.text)
        }
    }

    private enum Outcome: Sendable {
        case exited(Int32)
        case launchFailed(String)
        case timedOut
    }

    /// 起进程，等「退出」与「超时」谁先到。**只 resume 一次**，后到的那个什么都不做（超时那条还负责杀进程）。
    private static func launch(_ box: ProcessBox, timeout: Duration?) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let pending = Mutex<CheckedContinuation<Outcome, Never>?>(continuation)
            let resume: @Sendable (Outcome) -> Bool = { outcome in
                guard let continuation = pending.withLock({ slot -> CheckedContinuation<Outcome, Never>? in
                    defer { slot = nil }
                    return slot
                }) else { return false }
                continuation.resume(returning: outcome)
                return true
            }

            box.process.terminationHandler = { process in
                let status = process.terminationStatus
                let code = process.terminationReason == .uncaughtSignal ? 128 + status : status
                _ = resume(.exited(code))
            }

            do {
                try box.process.run()
            } catch {
                _ = resume(.launchFailed(error.localizedDescription))
                return
            }

            guard let timeout else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds(timeout)) {
                guard resume(.timedOut) else { return }   // 已经正常退出了
                box.process.terminate()
                let pid = box.process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                    if box.process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    /// 进程已退出：给输出一个很短的收尾窗口（最后几块数据可能还在路上），EOF 不来就不等了。
    private static func drain(_ collectors: [OutputCollector]) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: drainGrace)
        while clock.now < deadline, !collectors.allSatisfy(\.isAtEOF) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// `Process` 不是 `Sendable`，但它的三个跨线程用法（终止回调、超时里 terminate / 读 pid / isRunning）
/// 都是 Foundation 自己保证线程安全的操作。装箱只为跨过 `@Sendable` 闭包的边界。
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

/// 一根管道的读端：`readabilityHandler` 边来边收，不等 EOF 才读（防 64KB 死锁）。
private final class OutputCollector: @unchecked Sendable {

    let pipe = Pipe()
    private let state = Mutex<(data: Data, eof: Bool)>((Data(), false))

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.state.withLock { $0.eof = true }
            } else {
                self?.state.withLock { $0.data.append(chunk) }
            }
        }
    }

    var isAtEOF: Bool { state.withLock { $0.eof } }
    var text: String { state.withLock { String(decoding: $0.data, as: UTF8.self) } }

    /// 启动失败时拆掉 handler（没有进程会来写了）。
    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        state.withLock { $0.eof = true }
    }
}
