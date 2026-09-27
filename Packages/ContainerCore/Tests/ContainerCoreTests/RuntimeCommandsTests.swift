import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T4：升级链路用到的全部 CLI 调用（AD1：不经 XPC）。参数数组逐字断言——这里就是「不经 shell」的证据。
@Suite("RuntimeCommands：CLI 参数逐字、输出解析、lockf 映射")
struct RuntimeCommandsTests {

    static let cli = RuntimeCommands.cliPath
    let runner = FakeProcessRunner()

    func commands(lockPath: String = RuntimeCommands.lockPath) -> RuntimeCommands {
        RuntimeCommands(runner: runner, prober: FakeRuntimeProber(.down), lockPath: lockPath)
    }

    // MARK: - installedVersion

    /// F1 原样。
    @Test("解析真实的 --version 输出")
    func parsesRecordedVersionOutput() async {
        runner.respond(to: [Self.cli, "--version"], stdout: "container CLI version 1.4.1 (build: release, commit: 9a8917c)\n")
        #expect(await commands().installedVersion() == .installed(RuntimeVersion(major: 1, minor: 4, patch: 1)))
        #expect(runner.calls.first?.timeout == RuntimeCommands.versionTimeout)
    }

    @Test("二进制不存在 → notInstalled（不是 unknown，也不是「已是最新」）")
    func missingBinaryIsNotInstalled() async {
        runner.respond(to: [Self.cli, "--version"], with: .failure(.notFound(Self.cli)))
        #expect(await commands().installedVersion() == .notInstalled)
    }

    @Test(
        "读不出版本 → unknown",
        arguments: [
            Result<ProcessResult, ProcessRunError>.success(ProcessResult(exitCode: 1, stdout: "", stderr: "boom")),
            .success(ProcessResult(exitCode: 0, stdout: "container CLI version unknown (build: debug)\n", stderr: "")),
            .success(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
            .failure(.timedOut),
            .failure(.launchFailed("x")),
        ]
    )
    func unreadableVersionIsUnknown(result: Result<ProcessResult, ProcessRunError>) async {
        runner.respond(to: [Self.cli, "--version"], with: result)
        guard case .unknown = await commands().installedVersion() else {
            Issue.record("expected .unknown")
            return
        }
    }

    // MARK: - stop / start

    @Test("system stop：参数与超时")
    func stopRuntime() async {
        #expect(await commands().stopRuntime() == .succeeded)
        #expect(runner.calls == [.init(executable: Self.cli, arguments: ["system", "stop"], timeout: RuntimeCommands.stopTimeout)])
    }

    /// F8：内核缺失时 `system start` 会交互提问，stdin 读不到就抛错——显式 `--enable-kernel-install`（上游提问的默认答案）。
    @Test("system start：带 --enable-kernel-install，超时 300s")
    func startRuntime() async {
        #expect(await commands().startRuntime() == .succeeded)
        #expect(runner.calls == [.init(
            executable: Self.cli, arguments: ["system", "start", "--enable-kernel-install"], timeout: RuntimeCommands.startTimeout
        )])
        #expect(RuntimeCommands.startTimeout == .seconds(300))
    }

    @Test("非 0 退出 → failed，带 stderr 末尾")
    func failedCommandCarriesDetail() async {
        runner.respond(to: [Self.cli, "system", "stop"], exitCode: 1, stderr: "line1\nError: something broke\n")
        #expect(await commands().stopRuntime() == .failed(exitCode: 1, detail: "line1\nError: something broke"))
    }

    @Test("超时 / 不存在 → 各自的 outcome")
    func timeoutAndMissing() async {
        runner.respond(to: [Self.cli, "system", "stop"], with: .failure(.timedOut))
        runner.respond(to: [Self.cli, "system", "start", "--enable-kernel-install"], with: .failure(.notFound(Self.cli)))
        #expect(await commands().stopRuntime() == .timedOut)
        #expect(await commands().startRuntime() == .notInstalled)
    }

    // MARK: - 容器快照与恢复（AD6）

    @Test("ls --quiet：每行一个 ID，空行丢弃")
    func parsesRunningIDs() async throws {
        runner.respond(to: [Self.cli, "ls", "--quiet"], stdout: "buildkit\nopen-connector\n\n")
        let ids = try await commands().runningContainerIDs().get()
        #expect(ids.map(\.rawValue) == ["buildkit", "open-connector"])
    }

    @Test("ls 失败 → failure（不是「没有容器在跑」）")
    func runningIDsFailure() async {
        runner.respond(to: [Self.cli, "ls", "--quiet"], exitCode: 1, stderr: "Error: XPC connection error")
        guard case .failure = await commands().runningContainerIDs() else {
            Issue.record("expected failure")
            return
        }
    }

    /// `--` 截断选项解析：以 `-` 开头的 ID 也只会被当作位置参数（实测 `container start -- -h` 把 `-h` 当 ID）。
    @Test("start：参数数组为 [start, --, id]")
    func startContainerUsesDoubleDash() async throws {
        let id = try #require(ContainerID("-h"))
        #expect(await commands().startContainer(id) == .succeeded)
        #expect(runner.calls == [.init(
            executable: Self.cli, arguments: ["start", "--", "-h"], timeout: RuntimeCommands.containerStartTimeout
        )])
    }

    // MARK: - lockf 探测（AD4）

    @Test("lockf 退出码映射：0 / 69 → idle，75 → running，其他 → probeFailed", arguments: [
        (Int32(0), PrivilegedJobState.idle), (69, .idle), (75, .running), (73, .probeFailed(73)), (1, .probeFailed(1)),
    ])
    func lockProbeMapping(code: Int32, expected: PrivilegedJobState) async {
        runner.respond(
            to: ["/usr/bin/lockf", "-s", "-k", "-n", "-t", "0", RuntimeCommands.lockPath, "/usr/bin/true"], exitCode: code
        )
        #expect(await commands().privilegedJobState() == expected)
    }

    /// R2：锁迁到 `/private/var/db/cof-runtime-update/`——第一次升级之前那个**目录**都不存在。`lockf -n` 此时同样退出 69 → idle。
    @Test("真 lockf：锁文件的父目录不存在 → idle")
    func missingLockDirectoryIsIdle() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cof-lockf-missing-\(UUID().uuidString)").appendingPathComponent("L.lock").path
        let real = RuntimeCommands(runner: ProcessRunner(), prober: FakeRuntimeProber(.down), lockPath: missing)
        #expect(await real.privilegedJobState() == .idle)
        #expect(RuntimeCommands.lockPath.hasPrefix(PrivilegedInstallScript.stateDirectory + "/"))
    }

    /// 真 lockf、临时锁文件：锁文件不存在（= 第一次升级之前）→ idle；有人持锁 → running；放开 → idle。
    @Test("真 lockf 三态")
    func realLockfStates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cof-lockf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("L.lock").path
        let real = RuntimeCommands(runner: ProcessRunner(), prober: FakeRuntimeProber(.down), lockPath: lock)

        #expect(await real.privilegedJobState() == .idle)   // 文件不存在：69

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 9<>\"$1\"; /usr/bin/lockf -s -t 0 9 || exit 75; /bin/sleep 3", "x", lock]
        try holder.run()
        try await Task.sleep(for: .milliseconds(500))
        #expect(await real.privilegedJobState() == .running)

        // 不用 `waitUntilExit()`：它在协作线程上同步等 run loop 送达终止通知，而协作线程不跑 run loop——
        // 实测（Day 22 R4）持锁进程早已退出，它却永不返回，占住协作线程把整个测试进程饿死。
        while holder.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await real.privilegedJobState() == .idle)   // 文件还在、无人持锁：0
    }
}

/// 真机、只读（`--version`、`ls --quiet`）。`INTEGRATION=1 swift test --filter RuntimeCommandsIntegration`
@Suite(
    "RuntimeCommands 真机（INTEGRATION=1）",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1")
)
struct RuntimeCommandsIntegrationTests {

    let commands = RuntimeCommands()

    @Test("真读已装版本")
    func readsInstalledVersion() async {
        guard case .installed = await commands.installedVersion() else {
            Issue.record("expected .installed on a host with apple/container")
            return
        }
    }

    @Test("运行时在跑时，ls --quiet 与 prober 一致")
    func listsRunningContainers() async throws {
        guard await commands.isRuntimeRunning() else { return }
        _ = try await commands.runningContainerIDs().get()
    }
}
