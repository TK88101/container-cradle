import Foundation
import Testing

@testable import ContainerCore

/// **D3 的真机证明。**
///
/// 单测里的 `FakeProcessTable` 只能证明「匹配规则写对了」。它证明不了的是：
/// libproc 真的读得到 apiserver、`(pid, startTime)` 真的会随重启变化、
/// 我们盯的那个路径真的是它——**Fake 猜不出真实系统长什么样**（PLAN 的同一条纪律）。
///
/// ## 它默认不跑，而且必须默认不跑
///
/// 它会真的 `container system stop`——**你正在跑的容器会全部停掉，而且不会自己回来**
/// （那正是本 App 存在的理由）。测试收尾会把运行时和 `open-connector` 都拉回来，
/// 但这不是能塞进 PR 门禁里天天跑的东西。
///
/// ```sh
/// INTEGRATION=1 swift test --filter RuntimeProberIntegration
/// ```
@Suite(
    "RuntimeProber 真机（INTEGRATION=1）",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1")
)
struct RuntimeProberIntegrationTests {

    private let prober = ApiserverProber()

    /// 探测真实进程表：apiserver 此刻在跑，我们应当看得见它。
    @Test("真机：apiserver 在跑 → probe 报 running，且 pid 与 launchd 一致")
    func probesRealAPIServer() async throws {
        try requireRuntimeRunning()

        guard case .running(let generation) = await prober.probe() else {
            Issue.record("apiserver 在跑，但 probe 报了 down —— 匹配路径可能不对")
            return
        }

        #expect(generation.pid > 0)
        #expect(generation.startTime > 0)

        // 跟 launchd 的说法对一遍。**只信自己的 probe 等于自证**——
        // 而这里恰恰要防的是「盯错了进程」（同机还有个 machine-apiserver，名字里也带 apiserver）。
        #expect(generation.pid == (try launchdPID()))
    }

    /// ★ **整个 D3 的真机证明。**
    ///
    /// 运行时停掉 → probe 必须报 down；再起来 → 令牌必须**变**。
    /// 令牌不变的话，supervisor 会认为「还是同一条命」，容器再也不会被拉起——
    /// 而一切看起来都正常。
    @Test("真机：system stop → down；system start → running，且令牌变了")
    func generationChangesAcrossRestart() async throws {
        try requireRuntimeRunning()

        guard case .running(let before) = await prober.probe() else {
            Issue.record("前置条件不满足：apiserver 应该在跑")
            return
        }

        try shell("/usr/local/bin/container", ["system", "stop"])
        try await settle()

        #expect(await prober.probe() == .down)

        try shell("/usr/local/bin/container", ["system", "start"])
        try await settle()

        guard case .running(let after) = await prober.probe() else {
            Issue.record("system start 之后 apiserver 应该在跑")
            return
        }

        // ★ 换了一条命 → 令牌必须变。
        #expect(after != before)

        // 把用户的容器拉回来。**它不会自己回来**——这正是本 App 要补的那个洞，
        // 而在这个 App 装好之前，补洞的只能是这行代码。
        try? shell("/usr/local/bin/container", ["start", "open-connector"])
    }

    // MARK: -

    private func requireRuntimeRunning() throws {
        guard case .running = prober.probe() else {
            Issue.record("前置条件：apiserver 必须在跑（先 `container system start`）")
            throw CancellationError()
        }
    }

    /// launchd 认的那个 pid。**第二个信息源**——只信自己的 probe 等于自证。
    private func launchdPID() throws -> Int32 {
        let output = try shell("/bin/launchctl", ["list"])

        for line in output.split(separator: "\n") where line.contains("com.apple.container.apiserver") {
            if let pid = Int32(line.split(separator: "\t").first ?? "") { return pid }
        }

        throw CancellationError()
    }

    /// 运行时起停不是瞬时的：launchd 要拉起进程、apiserver 要绑上 Mach service。
    private func settle() async throws {
        try await Task.sleep(for: .seconds(3))
    }

    @discardableResult
    private func shell(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        // **硬编码绝对路径，不走 PATH**（防劫持——PLAN 给 `CLIProcessRunner` 定的同一条纪律）。
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }
}
