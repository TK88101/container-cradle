import ContainerCore
import ContainerizationError
import Testing

@testable import ContainerRuntime

/// Day 28（Plan 2026-11-10-pin-1.7.1 §2.1 b′）：create 前置短路。
///
/// 1.7.1 client 的 `containerConfigFromFlags` 在镜像不在本地时发 `.imagePlatforms`（1.6.1 起才有的路由）；
/// 1.6.0 server 对未知路由**不回复**（`XPCServer.swift:205` 无 else）⇒ 挂到 300s create 超时。
/// 短路条件：运行中 server < 1.6.1 **且**镜像确定不在本地（只认上游 `ClientImage.get` 的 `.notFound`）。
@Suite("CreatePreflight：旧运行时 × 未 pull 镜像短路")
struct CreatePreflightTests {

    private static func v(_ major: Int, _ minor: Int, _ patch: Int) -> RuntimeVersion {
        RuntimeVersion(major: major, minor: minor, patch: patch)
    }

    /// 记录 seam 被调用的次数。每条测试各自一个实例、closure 串行执行，故 `@unchecked Sendable` 安全。
    private final class Calls: @unchecked Sendable {
        var lookups = 0
        var assembles = 0
    }

    // MARK: - 纯函数：哪个版本需要确认镜像在本地

    @Test(
        "< 1.6.1 需要确认；≥ 1.6.1 与不可解析都放行",
        arguments: [
            (Optional(v(1, 5, 0)), Optional(v(1, 5, 0))),
            (Optional(v(1, 6, 0)), Optional(v(1, 6, 0))),
            (Optional(v(1, 6, 1)), nil),
            (Optional(v(1, 7, 1)), nil),
            (nil, nil),
        ] as [(RuntimeVersion?, RuntimeVersion?)]
    )
    func versionRequiringLocalImage(server: RuntimeVersion?, expected: RuntimeVersion?) {
        #expect(CreatePreflight.versionRequiringLocalImage(serverVersion: server) == expected)
    }

    // MARK: - 编排：短路时零装配

    @Test("旧运行时 + 不在本地 ⇒ 抛 runtimeTooOldForRemoteImage，零装配")
    func oldRuntimeRemoteImageIsBlocked() async {
        let calls = Calls()
        await #expect(throws: RuntimeError.creation(.runtimeTooOldForRemoteImage(running: Self.v(1, 6, 0)))) {
            try await CreatePreflight.run(
                serverVersion: Self.v(1, 6, 0),
                isImageLocal: { calls.lookups += 1; return false },
                assemble: { calls.assembles += 1; return "id" }
            )
        }
        #expect(calls.lookups == 1)
        #expect(calls.assembles == 0)
    }

    @Test("旧运行时 + 在本地 ⇒ 照常装配")
    func oldRuntimeLocalImageProceeds() async throws {
        let calls = Calls()
        let id = try await CreatePreflight.run(
            serverVersion: Self.v(1, 6, 0),
            isImageLocal: { calls.lookups += 1; return true },
            assemble: { calls.assembles += 1; return "id" }
        )
        #expect(id == "id")
        #expect(calls.assembles == 1)
    }

    @Test("新运行时 / 版本不可解析 ⇒ 不查本地、直接装配", arguments: [Optional(v(1, 6, 1)), Optional(v(1, 7, 1)), nil])
    func newOrUnknownRuntimeSkipsLookup(server: RuntimeVersion?) async throws {
        let calls = Calls()
        _ = try await CreatePreflight.run(
            serverVersion: server,
            isImageLocal: { calls.lookups += 1; return false },
            assemble: { calls.assembles += 1; return "id" }
        )
        #expect(calls.lookups == 0)
        #expect(calls.assembles == 1)
    }

    @Test("本地查询自身出错 ⇒ 原样抛出，不当成「不在本地」，零装配")
    func lookupErrorPropagates() async {
        let calls = Calls()
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            try await CreatePreflight.run(
                serverVersion: Self.v(1, 6, 0),
                isImageLocal: { throw Boom() },
                assemble: { calls.assembles += 1; return "id" }
            )
        }
        #expect(calls.assembles == 0)
    }

    // MARK: - 上游 `get` 的错误 → 本地性

    @Test("只有 .notFound 判为不在本地")
    func onlyNotFoundMeansRemote() async throws {
        #expect(try await CreatePreflight.isPresent {} == true)
        #expect(try await CreatePreflight.isPresent { throw ContainerizationError(.notFound, message: "image x") } == false)
    }

    @Test("其它上游错误原样抛出", arguments: [ContainerizationError.Code.internalError, .invalidArgument, .timeout])
    func otherErrorsPropagate(code: ContainerizationError.Code) async {
        await #expect(throws: ContainerizationError.self) {
            _ = try await CreatePreflight.isPresent { throw ContainerizationError(code, message: "boom") }
        }
    }
}
