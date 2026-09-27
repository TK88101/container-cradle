import Foundation
import Synchronization
import Testing

@testable import ContainerCore

/// Day 22 T5（驱动器）：起 osascript、等 root 的状态文件、恰好一次 `onReady`、结果只看 root 的输出。
///
/// A5 的时序不变式在这里守：**状态文件出现之前，`onReady`（store 在里面 stop 运行时）一次都不许被调用**。
@Suite("PrivilegedInstaller：状态文件出现才 onReady，且只一次")
struct PrivilegedInstallerTests {

    static let digest = SHA256Digest(hex: String(repeating: "c", count: 64))!
    static let version = RuntimeVersion(major: 1, minor: 5, patch: 0)

    /// 模拟 osascript：按脚本创建（或不创建）状态文件，再返回结果。
    final class ScriptedOsascript: ProcessRunning, @unchecked Sendable {
        let stateFile: String
        let writesReadyAfter: Duration?
        let holdAfterReady: Duration
        let result: ProcessResult
        let received = Mutex<[String]?>(nil)
        let readyWrittenAt = Mutex<ContinuousClock.Instant?>(nil)

        init(stateFile: String, writesReadyAfter: Duration?, holdAfterReady: Duration = .milliseconds(400), result: ProcessResult) {
            self.stateFile = stateFile
            self.writesReadyAfter = writesReadyAfter
            self.holdAfterReady = holdAfterReady
            self.result = result
        }

        func run(_ executable: String, arguments: [String], timeout: Duration?) async throws(ProcessRunError) -> ProcessResult {
            received.withLock { $0 = [executable] + arguments }
            if let delay = writesReadyAfter {
                try? await Task.sleep(for: delay)
                try? "phase=ready\n".write(toFile: stateFile, atomically: true, encoding: .utf8)
                readyWrittenAt.withLock { $0 = ContinuousClock.now }
                try? await Task.sleep(for: holdAfterReady)
            }
            return result
        }
    }

    final class ReadyRecorder: @unchecked Sendable {
        let calls = Mutex<[ContinuousClock.Instant]>([])
        var count: Int { calls.withLock { $0.count } }
        func record() { calls.withLock { $0.append(ContinuousClock.now) } }
    }

    static func installer(_ runner: ProcessRunning, dir: TempDir) -> PrivilegedInstaller {
        PrivilegedInstaller(runner: runner, stateDirectory: dir.url.path, waitSeconds: 300)
    }

    static func stateFile(_ dir: TempDir, _ nonce: UUID) -> String {
        dir.path("cof-runtime-update.\(nonce.uuidString)")
    }

    @Test("osascript 的参数就是 PrivilegedInstallScript 构造的那一组")
    func passesExactArguments() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        let fake = ScriptedOsascript(
            stateFile: Self.stateFile(dir, nonce), writesReadyAfter: nil,
            result: ProcessResult(exitCode: 0, stdout: "COF_RESULT=digest-mismatch\r", stderr: "")
        )
        _ = await Self.installer(fake, dir: dir).run(
            package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P", onReady: {}
        )
        #expect(fake.received.withLock { $0 } == ["/usr/bin/osascript"] + PrivilegedInstallScript.osascriptArguments(
            packagePath: "/tmp/u.pkg", digest: Self.digest, ownerUID: getuid(), nonce: nonce, waitSeconds: 300,
            target: Self.version, prompt: "P"
        ))
    }

    /// A5：取消 ⇒ root 从未写状态文件 ⇒ onReady（stop 运行时）一次都没发生。
    @Test("密码框取消 → cancelled，onReady 零次")
    func cancelNeverCallsReady() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        let recorder = ReadyRecorder()
        let fake = ScriptedOsascript(
            stateFile: Self.stateFile(dir, nonce), writesReadyAfter: nil,
            result: ProcessResult(exitCode: 1, stdout: "", stderr: "0:1: execution error: User canceled. (-128)\n")
        )
        let outcome = await Self.installer(fake, dir: dir).run(
            package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P",
            onReady: { recorder.record() }
        )
        #expect(outcome == .cancelled)
        #expect(recorder.count == 0)
    }

    @Test("复验失败（ready 之前退出）→ 结果照实返回，onReady 零次")
    func verificationFailureNeverCallsReady() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        let recorder = ReadyRecorder()
        let fake = ScriptedOsascript(
            stateFile: Self.stateFile(dir, nonce), writesReadyAfter: nil,
            result: ProcessResult(exitCode: 0, stdout: "COF_RESULT=signer-untrusted\r", stderr: "")
        )
        let outcome = await Self.installer(fake, dir: dir).run(
            package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P",
            onReady: { recorder.record() }
        )
        #expect(outcome == .finished(.signerUntrusted, blockers: [], details: []))
        #expect(recorder.count == 0)
    }

    @Test("状态文件出现 → onReady 恰好一次，且在文件写出之后")
    func readyCalledOnceAfterStateFile() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        let recorder = ReadyRecorder()
        let fake = ScriptedOsascript(
            stateFile: Self.stateFile(dir, nonce), writesReadyAfter: .milliseconds(300), holdAfterReady: .seconds(1),
            result: ProcessResult(exitCode: 0, stdout: "COF_RESULT=installed\r", stderr: "")
        )
        let outcome = await Self.installer(fake, dir: dir).run(
            package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P",
            onReady: { recorder.record() }
        )
        #expect(outcome == .finished(.installed, blockers: [], details: []))
        #expect(recorder.count == 1)
        let written = try #require(fake.readyWrittenAt.withLock { $0 })
        let called = try #require(recorder.calls.withLock { $0.first })
        #expect(called >= written)
    }

    /// 别的 nonce 的状态文件（旧任务的残留）不算数。
    @Test("别的 nonce 的状态文件不触发 onReady")
    func ignoresOtherNonce() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        try "phase=ready\n".write(toFile: Self.stateFile(dir, UUID()), atomically: true, encoding: .utf8)
        let recorder = ReadyRecorder()
        let fake = ScriptedOsascript(
            stateFile: Self.stateFile(dir, nonce), writesReadyAfter: nil,
            result: ProcessResult(exitCode: 1, stdout: "", stderr: "(-128)")
        )
        _ = await Self.installer(fake, dir: dir).run(
            package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P",
            onReady: { recorder.record() }
        )
        #expect(recorder.count == 0)
    }

    /// codex R1 [P1]：root 在 install 模式下先设 STATE 再复验；复验失败会写 `phase=done`。
    /// 那不是「已授权且复验通过」——绝不能因此去停运行时。
    @Test("状态文件是 done（复验失败）而非 ready → onReady 零次")
    func doneWithoutReadyNeverCallsReady() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        let recorder = ReadyRecorder()
        final class WritesDone: ProcessRunning, @unchecked Sendable {
            let path: String
            init(path: String) { self.path = path }
            func run(_ executable: String, arguments: [String], timeout: Duration?) async throws(ProcessRunError) -> ProcessResult {
                try? "phase=done\nresult=digest-mismatch\n".write(toFile: path, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(600))
                return ProcessResult(exitCode: 0, stdout: "COF_RESULT=digest-mismatch\r", stderr: "")
            }
        }
        let outcome = await Self.installer(WritesDone(path: Self.stateFile(dir, nonce)), dir: dir).run(
            package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P",
            onReady: { recorder.record() }
        )
        #expect(outcome == .finished(.digestMismatch, blockers: [], details: []))
        #expect(recorder.count == 0)
    }

    /// 安全评审 L9：App 在 preparing 阶段退出时会取消 store 的任务。此后驱动器不许再轮询（`Task.sleep` 被取消后立即抛错 ⇒ 忙转），
    /// 更不许在退出途中看到 ready 就去 onReady——那会让一个正在退出的 App 停掉运行时。
    @Test("调用方已取消 → 不再 onReady（即使 ready 随后出现）")
    func cancelledCallerNeverCallsReady() async throws {
        let dir = try TempDir()
        let nonce = UUID()
        let recorder = ReadyRecorder()
        let fake = ScriptedOsascript(
            stateFile: Self.stateFile(dir, nonce), writesReadyAfter: .milliseconds(300), holdAfterReady: .milliseconds(700),
            result: ProcessResult(exitCode: 0, stdout: "COF_RESULT=stop-timeout\r", stderr: "")
        )
        let installer = Self.installer(fake, dir: dir)
        let task = Task {
            await installer.run(
                package: URL(fileURLWithPath: "/tmp/u.pkg"), digest: Self.digest, version: Self.version, nonce: nonce, prompt: "P",
                onReady: { recorder.record() }
            )
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .finished(.stopTimeout, blockers: [], details: []))
        #expect(fake.readyWrittenAt.withLock { $0 } != nil)
        #expect(recorder.count == 0)
    }

    @Test("readStateFile：按 nonce 读、读不到 → nil")
    func readsStateFile() throws {
        let dir = try TempDir()
        let nonce = UUID()
        let installer = Self.installer(FakeProcessRunner(), dir: dir)
        #expect(installer.readStateFile(nonce: nonce) == nil)
        try "phase=done\nresult=install-failed\n".write(toFile: Self.stateFile(dir, nonce), atomically: true, encoding: .utf8)
        #expect(installer.readStateFile(nonce: nonce) == .done(.installFailed))
    }
}
