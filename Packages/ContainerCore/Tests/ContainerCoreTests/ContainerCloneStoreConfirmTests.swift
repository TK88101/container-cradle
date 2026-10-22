import Foundation
import Testing

@testable import ContainerCore

/// Day 25（Plan 2026-10-22 T5）：clone 超时后同样凭 operationID 取回那一次的结果（clone 不启动）。
@MainActor
@Suite("ContainerCloneStore：超时后的确认段")
struct ContainerCloneStoreConfirmTests {

    private static let clock = Date(timeIntervalSince1970: 2_000_000)

    private func container(_ name: String) throws -> Container {
        Container(
            id: try #require(ContainerID(name)),
            image: try #require(ImageRef("docker.io/library/alpine:latest")),
            state: .stopped,
            environment: []
        )
    }

    /// 源容器 `src` 在库；clone 的 create 超时、带回 `op`。
    private func timingOutClient(_ op: CreationOperationID?) async throws -> FakeContainerRuntimeClient {
        let client = FakeContainerRuntimeClient(containers: [try container("src")])
        await client.inject(.outcomeUnknown(reason: "XPC call timed out", pending: op), for: .createClone)
        return client
    }

    private func store(_ client: FakeContainerRuntimeClient) throws -> ContainerCloneStore {
        let sut = ContainerCloneStore(source: try #require(ContainerID("src")), client: client, now: { Self.clock })
        sut.newName = "web"
        return sut
    }

    @Test("超时 → 取回成功 ⇒ succeeded（不调 start）")
    func lateSuccess() async throws {
        let op = CreationOperationID()
        let client = try await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .success(try container("web")))
        let sut = try store(client)

        await sut.submit()

        #expect(sut.phase == .succeeded(try #require(ContainerID("web"))))
        let calls = await client.calls
        #expect(calls.contains(.awaitPendingCreation(op)))
        #expect(!calls.contains { if case .start = $0 { true } else { false } })
        #expect(sut.submittedAt == nil)
    }

    @Test("超时 → 取回确定失败 ⇒ createFailed(那个错误)")
    func lateFailure() async throws {
        let op = CreationOperationID()
        let client = try await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .failure(.operationFailed(reason: "boom")))
        let sut = try store(client)

        await sut.submit()

        #expect(sut.phase == .failed(.createFailed(.operationFailed(reason: "boom"))))
    }

    @Test("超时 → 预算内仍没结果 ⇒ abandon，终态 outcomeUnknown 不带 operationID")
    func stillUnknownAbandons() async throws {
        let op = CreationOperationID()
        let client = try await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .failure(.outcomeUnknown(reason: "still", pending: op)))
        let sut = try store(client)

        await sut.submit()

        #expect(sut.phase == .failed(.createFailed(.outcomeUnknown(reason: "still", pending: nil))))
        #expect((await client.calls).contains(.abandonPendingCreation(op)))
    }

    @Test("没带 operationID 的超时 ⇒ 不进确认段")
    func timeoutWithoutOperation() async throws {
        let client = try await timingOutClient(nil)
        let sut = try store(client)

        await sut.submit()

        #expect(sut.phase == .failed(.createFailed(.outcomeUnknown(reason: "XPC call timed out", pending: nil))))
        #expect(!(await client.calls).contains { if case .awaitPendingCreation = $0 { true } else { false } })
    }

    @Test("同名在途被挡 ⇒ 终态，不订阅")
    func creationInProgressIsTerminal() async throws {
        let client = FakeContainerRuntimeClient(containers: [try container("src")])
        await client.inject(.creationInProgress(name: "web"), for: .createClone)
        let sut = try store(client)

        await sut.submit()

        #expect(sut.phase == .failed(.createFailed(.creationInProgress(name: "web"))))
        #expect(!(await client.calls).contains { if case .awaitPendingCreation = $0 { true } else { false } })
    }

    @Test("确认中：isBusy、submittedAt 已置；新的 submit 被单飞门拒")
    func confirmingRejectsResubmit() async throws {
        let op = CreationOperationID()
        let client = try await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .success(try container("web")))
        await client.holdPendingCreationAwaits()
        let sut = try store(client)

        let first = Task { await sut.submit() }
        while sut.phase != .confirming { await Task.yield() }

        #expect(sut.phase.isBusy)
        #expect(sut.submittedAt == Self.clock)

        // 同 create store：不直接 await 第二次 submit，看它有没有越过单飞门去调 list。
        let second = Task { await sut.submit() }
        for _ in 0..<50 { await Task.yield() }
        #expect((await client.calls).filter { $0 == .list }.count == 1, "确认中的第二次 submit 越过了单飞门")

        await client.releasePendingCreationAwaits()
        #expect(await first.value)
        #expect(await second.value == false)
        #expect(sut.phase == .succeeded(try #require(ContainerID("web"))))
    }
}
