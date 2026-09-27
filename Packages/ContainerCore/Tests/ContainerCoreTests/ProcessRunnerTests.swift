import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T4：起子进程的那一层。**真进程**测试——这一层的全部风险都在「和真实进程打交道」上，fake 测不出来。
///
/// 每条都对应一个已知的坑：
/// - env 白名单：子进程绝不继承 App 的 env（PLAN「子进程 env 白名单」，本仓库第一次真正 shell-out）；
/// - stdin 接空设备：`codex exec` 缺 `</dev/null` 死等 7.5 小时（memory）——读 stdin 的子进程必须立刻读到 EOF；
/// - 双管道并发排空：只在退出后读 stdout，输出 > 64KB 时子进程写满管道、父进程等它退出 → 死锁；
/// - 超时即杀且**不等**：`withThrowingTaskGroup` 做不出超时（CLAUDE.md ★）；
/// - 后台孙进程继承了管道：EOF 迟迟不来，也不能把调用方卡住。
@Suite("ProcessRunner：env 白名单、不读 stdin、不死锁、超时不等", .serialized)
struct ProcessRunnerTests {

    let runner = ProcessRunner()

    @Test("退出码、stdout、stderr 分开拿到")
    func capturesOutputsAndExitCode() async throws {
        let result = try await runner.run("/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test("参数原样到达，不经 shell 解释")
    func argumentsAreNotShellInterpreted() async throws {
        let hostile = "a b'c\"$(whoami);`id`"
        let result = try await runner.run("/bin/echo", arguments: [hostile])
        #expect(result.stdout == hostile + "\n")
    }

    @Test("env 只含白名单 + 固定 PATH / LC_ALL")
    func environmentIsWhitelisted() async throws {
        setenv("COF_PROCESS_RUNNER_TEST_SECRET", "leak", 1)
        defer { unsetenv("COF_PROCESS_RUNNER_TEST_SECRET") }

        let result = try await runner.run("/usr/bin/env", arguments: [])
        let keys = Set(result.stdout.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })

        #expect(!keys.contains("COF_PROCESS_RUNNER_TEST_SECRET"))
        #expect(keys.isSubset(of: Set(ProcessRunner.inheritedEnvironmentKeys + ["PATH", "LC_ALL"])))
        #expect(result.stdout.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"))
        #expect(result.stdout.contains("LC_ALL=C\n"))
    }

    @Test("读 stdin 的子进程立刻读到 EOF，不会死等")
    func stdinIsNullDevice() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run("/bin/cat", arguments: [], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(clock.now - start < .seconds(3))
    }

    @Test("大输出（200KB）不死锁")
    func largeOutputDoesNotDeadlock() async throws {
        let result = try await runner.run(
            "/bin/sh", arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 200000; /usr/bin/yes y | /usr/bin/head -c 100000 >&2"],
            timeout: .seconds(20)
        )
        #expect(result.stdout.utf8.count == 200_000)
        #expect(result.stderr.utf8.count == 100_000)
    }

    /// 挂死用 `sleep 600`——它不响应我们的等待，只响应信号，正是「真挂死」的样子。
    @Test("超时：立即返回 timedOut，不等进程退出")
    func timeoutReturnsWithoutWaiting() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessRunError.timedOut) {
            _ = try await runner.run("/bin/sleep", arguments: ["600"], timeout: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test("可执行文件不存在 → notFound")
    func missingExecutable() async {
        await #expect(throws: ProcessRunError.notFound("/nonexistent/cof-no-such-binary")) {
            _ = try await runner.run("/nonexistent/cof-no-such-binary", arguments: [])
        }
    }

    /// 子进程退出了，但它留下的后台孙进程还攥着 stdout——EOF 要等孙进程退出才来。不能因此把调用方卡住。
    @Test("后台孙进程占着管道：按退出返回，已有输出不丢")
    func backgroundGrandchildHoldingPipe() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run("/bin/sh", arguments: ["-c", "echo done; (/bin/sleep 8 &)"], timeout: .seconds(20))
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("done\n"))
        #expect(clock.now - start < .seconds(5))
    }

    @Test("被信号杀死 → 128 + 信号号（与 shell 惯例一致）")
    func killedBySignal() async throws {
        let result = try await runner.run("/bin/sh", arguments: ["-c", "kill -TERM $$"])
        #expect(result.exitCode == 128 + 15)
    }
}
