import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// `LiveContainerRuntimeClient.delete(id:)`——删除容器的确定序列（Day 16 T6.3，§3.4 / codex #12）。
///
/// 序列：**前置 get 复核** → `delete(force:true)` → 报错时**仅 runtime 可达才复核**
/// （已删=幂等成功；仍在=真失败）。**绝不把「get/delete 失败」解读成「容器不存在」**——
/// runtime-down 与 not-found 不可混（codex #12，R14 同款病）。
/// 这里断言的是**调用序列/计数**（复核有没有发生、delete 有没有被跳过），不断言下游副作用。
@Suite("LiveContainerRuntimeClient.delete：显式序列与 not-found/runtime-down 隔离")
struct LiveContainerRuntimeClientDeleteTests {

    private func client(upstream: FakeUpstreamClient, prober: FakeRuntimeProber) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: prober,
            stopTimeout: .seconds(5)
        )
    }

    private func present() throws -> (snapshot: ContainerSnapshot, id: ContainerID) {
        let snapshot = try Fixtures.openConnector()
        let id = try #require(ContainerID(snapshot.id))
        return (snapshot, id)
    }

    @Test("存在 → delete(force:true) 一次，成功收官")
    func existsThenDeletesWithForce() async throws {
        let (snapshot, id) = try present()
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        let sut = client(upstream: upstream, prober: .up)

        try await sut.delete(id: id)

        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue), .deleteContainer(id: id.rawValue, force: true)])
    }

    @Test("前置复核确实不存在（runtime up + 真 not-found）→ containerNotFound，且 delete 从未被调用")
    func precheckAbsentThrowsNotFoundWithoutDeleting() async throws {
        let (_, id) = try present()
        let upstream = FakeUpstreamClient()   // 没有这个快照 → get 抛真 .notFound
        let sut = client(upstream: upstream, prober: .up)

        await #expect(throws: RuntimeError.containerNotFound(id)) {
            try await sut.delete(id: id)
        }
        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue)])   // 没有 deleteContainer
    }

    @Test("★前置 get 无法确定存在性（映射失败，runtime up）→ 原样抛，绝不谎报 not-found、不 delete（codex P1）")
    func precheckIndeterminateDoesNotClaimNotFound() async throws {
        let (snapshot, id) = try present()
        // get 注入一个「非 not-found」的失败（如 XPC 超时/映射失败），prober 仍说 up → 映成 operationFailed。
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setFailGet(FakeUpstreamClient.Failure(label: "get 超时/映射失败"))
        let sut = client(upstream: upstream, prober: .up)

        do {
            try await sut.delete(id: id)
            Issue.record("应当抛错")
        } catch {
            // 关键：是 operationFailed（存在性未确定），**不是** containerNotFound——绝不把 get 失败读成不存在。
            guard case .operationFailed = error else {
                Issue.record("期望 .operationFailed（indeterminate），得到 \(error)")
                return
            }
        }
        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue)])   // 存在性没确立 → 绝不 delete
    }

    @Test("前置复核时 runtime down → runtimeUnavailable，delete 从未被调用（不谎称不存在）")
    func precheckRuntimeDownThrowsUnavailableWithoutDeleting() async throws {
        let (_, id) = try present()
        let upstream = FakeUpstreamClient()
        let sut = client(upstream: upstream, prober: .down)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            try await sut.delete(id: id)
        }
        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue)])
    }

    @Test("delete 报错但复核已不存在（runtime up）→ 当幂等成功，不抛")
    func deleteErrorButGoneIsIdempotentSuccess() async throws {
        let (snapshot, id) = try present()
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setFailDelete(FakeUpstreamClient.Failure(label: "spurious"))
        // 默认 removeSnapshotOnDelete=true：delete 尝试后快照消失 → 复核报不存在。
        let sut = client(upstream: upstream, prober: .up)

        try await sut.delete(id: id)   // 不抛

        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue), .deleteContainer(id: id.rawValue, force: true), .get(id.rawValue)])
    }

    @Test("delete 报错且复核仍在（runtime up）→ 真失败，原样抛")
    func deleteErrorAndStillPresentRethrows() async throws {
        let (snapshot, id) = try present()
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setFailDelete(FakeUpstreamClient.Failure(label: "real failure"))
        await upstream.setRemoveSnapshotOnDelete(false)   // 快照仍在 → 复核报存在
        let sut = client(upstream: upstream, prober: .up)

        await #expect(throws: RuntimeError.self) {
            try await sut.delete(id: id)
        }
        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue), .deleteContainer(id: id.rawValue, force: true), .get(id.rawValue)])
    }

    @Test("delete 报错且 runtime down → runtimeUnavailable 原样抛，绝不复核、绝不解读成不存在（codex #12）")
    func deleteErrorRuntimeDownRethrowsWithoutRecheck() async throws {
        let (snapshot, id) = try present()
        // 快照存在 → 前置 get 成功（get 成功不问 prober）；delete 报错时 prober 说 down。
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setFailDelete(FakeUpstreamClient.Failure(label: "xpc invalid"))
        let sut = client(upstream: upstream, prober: .down)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            try await sut.delete(id: id)
        }
        let calls = await upstream.calls
        // 没有第二个 .get——runtime down 时不复核（复核会把 runtime-down 误读成 not-found）。
        #expect(calls == [.get(id.rawValue), .deleteContainer(id: id.rawValue, force: true)])
    }

    @Test("★delete 报错且复核无法确定存在性（runtime up 但 get 超时/映射失败）→ 抛原错，绝不谎称删成功（codex P1）")
    func deleteErrorAndIndeterminateRecheckDoesNotClaimSuccess() async throws {
        let (snapshot, id) = try present()
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setFailDelete(FakeUpstreamClient.Failure(label: "real failure"))
        // delete 之后复核 get 抛「非 not-found」的失败（超时/映射失败）——存在性无法确定。
        await upstream.setGetFailsAfterDelete(FakeUpstreamClient.Failure(label: "recheck get 超时/映射失败"))
        let sut = client(upstream: upstream, prober: .up)

        // 修复前：复核把 indeterminate 当 absent → 静默「幂等成功」→ 本断言会失败（不抛）。
        await #expect(throws: RuntimeError.self) {
            try await sut.delete(id: id)
        }
        let calls = await upstream.calls
        #expect(calls == [.get(id.rawValue), .deleteContainer(id: id.rawValue, force: true), .get(id.rawValue)])
    }

    @Test("delete 卡死 → 在 XPCTimeout 后返回，不冻住")
    func deleteHangReturnsAfterTimeout() async throws {
        let (snapshot, id) = try present()
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setHangDelete(true)
        let sut = LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(),
            prober: FakeRuntimeProber.up,
            timeout: .milliseconds(50)
        )

        await #expect(throws: RuntimeError.self) {
            try await sut.delete(id: id)
        }
    }
}
