import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// **诊断用**（M3 验收红了之后加的）：对一个**停着**的容器真的打一次 `start()`，
/// 把抛出来的 domain error 原样打出来。
///
/// App 里没有日志，于是 supervisor 熔断时「它为什么失败」是不可见的——
/// 这个洞本身就是 Day 7 的一个遗漏。这条测试是临时的替代品。
///
/// `CANARY=<容器ID> swift test` 才跑。**它会真的去起容器**，所以必须显式点名起哪一个。
@Suite(
    "诊断：真的 start 一个停着的容器",
    .enabled(if: ProcessInfo.processInfo.environment["CANARY"] != nil)
)
struct CanaryDiagnosticTests {

    @Test("start 一个停着的容器，报告成败与真实错误")
    func startStoppedContainer() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["CANARY"])
        let id = try #require(ContainerID(raw))

        let client = LiveContainerRuntimeClient()

        do {
            try await client.start(id: id)
            print("★ CANARY-RESULT: start() 成功")
        } catch {
            print("★ CANARY-RESULT: start() 失败 → \(error)")
            print("★ CANARY-KIND: \(FailureKind(from: error))")

            throw error
        }
    }
}
