import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// **真机验证：live client 真的连得上 XPC。**
///
/// 前面 24 条测试全绿，但它们喂的都是 Fake——`LiveUpstreamClient`（唯一真打 XPC 的那层）
/// **一次都没跑过**。而这个仓库已经吃过一次亏：
/// 「编译过 ≠ 跑得起来」「`swift test` 不构建 app target」（CLAUDE.md）。
/// 被豁免的那一层，正是最容易藏 P1 的地方（`LibprocProcessTable` 的 1/4 进程 bug）。
///
/// ## 刻意没有副作用
///
/// 只做两件事：`list()`，以及对一个**已在运行**的容器 `start()`——后者走幂等短路，
/// 只会发一次 `get`，不会动用户的任何容器。
///
/// 真正的「停掉运行时 → 容器被自动拉起」端到端要等 Day 7（composition root 接线之后），
/// 那是 M3 的验收。
///
/// `INTEGRATION=1 swift test` 才跑。
@Suite(
    "真机：live client 连得上 XPC",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1")
)
struct LiveClientIntegrationTests {

    @Test("真 XPC：list() 拿到真实容器，并映射成 domain")
    func listsRealContainers() async throws {
        let client = LiveContainerRuntimeClient()

        let containers = try await client.list()

        // 本机至少有 open-connector（spike 实测）。数量不写死——用户可能加了别的容器。
        #expect(!containers.isEmpty, "真机上一个容器都没有？先 container ls 确认")

        // 映射真的发生了：ID 与 image 都是 domain 类型，不是上游类型。
        for container in containers {
            #expect(!container.id.rawValue.isEmpty)
            #expect(!container.image.rawValue.isEmpty)
        }

        // ★ **D2 的真机验证**：真容器的 env 里是**真密钥**（实测 3 个 44 字符的）。
        // 把整个 Container 插值出来，明文一个字都不许出现——这里不断言具体密钥
        // （那要求测试自己知道密钥，反而制造了一个泄漏点），断言的是：
        // 凡是有 env 的容器，它的值在输出里只能是 `<redacted>`。
        for container in containers where !container.environment.isEmpty {
            #expect(
                "\(container)".contains("<redacted>"),
                "真机容器的 env 值没有被打码——D2 在真数据上失效了"
            )
        }
    }

    /// 幂等短路的真机验证：对一个**已在运行**的容器下 `start`，必须静默成功。
    ///
    /// 这条路径 supervisor 每一轮都会走到（轮询看见容器已在跑 → 不该做任何事）。
    /// 它在真机上必须是 no-op，否则 supervisor 会反复 bootstrap 一个好好的容器。
    @Test("真 XPC：对已在运行的容器 start() → 幂等短路，无副作用")
    func startOnRunningContainerIsNoOp() async throws {
        let client = LiveContainerRuntimeClient()

        let containers = try await client.list()
        guard let running = containers.first(where: { $0.state == .running }) else {
            // 没有正在跑的容器就没什么可测的——但**不能静默通过**，
            // 否则这条测试会在「什么都没测」的情况下常绿。
            Issue.record("真机上没有 running 的容器，这条测试没测到东西（先起一个再跑）")
            return
        }

        // 已在运行 → 应当静默成功（不抛、不 bootstrap）。
        try await client.start(id: running.id)

        // 它还在跑（我们没把它弄坏）。
        let after = try await client.list()
        #expect(after.first { $0.id == running.id }?.state == .running)
    }

    /// 真机 stats smoke（Day 9 T10 DoD）：对一个**已在运行**的容器取一次样本。
    /// 只读、无副作用——`stats(id:)` 是纯查询，不动容器。
    ///
    /// 不断言具体数值（那随机器负载变），只断言：XPC 真的返回了一个样本，且**至少一个
    /// 计数器有值**——一个 running 的容器不可能内存、CPU 全是 `nil`（那说明映射断了）。
    @Test("真 XPC：对已在运行的容器 stats() → 拿到一个样本，映射成 domain")
    func statsOnRunningContainer() async throws {
        let client = LiveContainerRuntimeClient()

        let containers = try await client.list()
        guard let running = containers.first(where: { $0.state == .running }) else {
            Issue.record("真机上没有 running 的容器，这条测试没测到东西（先起一个再跑）")
            return
        }

        let sample = try await client.stats(id: running.id)

        // 一个真在跑的容器至少占着内存——全 nil 说明 StatsMapper 或 XPC 解码断了。
        let hasAnyCounter =
            sample.memoryUsageBytes != nil
            || sample.cpuUsageUsec != nil
            || sample.memoryLimitBytes != nil
        #expect(hasAnyCounter, "running 容器的 stats 全是 nil——映射断了或 XPC 没返回数据")
    }

    /// 真机 followLogs smoke（Day 9 T6）：对一个 running 容器**真的建起日志流**。
    ///
    /// 前面 fd 接线（readabilityHandler / 行装配 / onTermination 关 fd / 超时）都用 `Pipe` 测过；
    /// 唯一没被真机验证的是 **`upstream.logs(id:)` 这次真 XPC 调用**——apiserver 真的会
    /// 通过 XPC 把日志文件的 fd 传回来吗？这条 smoke 就守这个：`followLogs` 不抛错 = XPC
    /// 拿到了 fd、流建起来了。**刻意不断言收到具体日志行**（那取决于容器此刻有没有在写，
    /// 会让测试变得不确定——CLAUDE.md 的坑），只断言真 XPC 的 fd 交接这一步成立。
    /// 建完流立刻取消，`onTermination` 会关掉 fd（Pipe 测试已覆盖清理路径）。
    @Test("真 XPC：对已在运行的容器 followLogs() → 真的建起日志流（fd 交接成立）")
    func followLogsOnRunningContainer() async throws {
        let client = LiveContainerRuntimeClient()

        let containers = try await client.list()
        guard let running = containers.first(where: { $0.state == .running }) else {
            Issue.record("真机上没有 running 的容器，这条测试没测到东西（先起一个再跑）")
            return
        }

        // 不抛 = 真 XPC 拿到了 fd、AsyncThrowingStream 建起来了。
        let stream = try await client.followLogs(id: running.id)

        // 立刻收工：起一个消费者又马上取消，触发 onTermination 关 fd（不泄漏）。
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
    }
}
