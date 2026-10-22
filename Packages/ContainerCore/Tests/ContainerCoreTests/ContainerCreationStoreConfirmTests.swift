import Foundation
import Testing

@testable import ContainerCore

/// Day 25（Plan 2026-10-22 §2.1 / §2.3 / T4）：create 超时后，store 凭 operationID 取回**那一次**的真实结果；
/// 「创建并启动」只在拿到成功时才补上启动；确认中照样单飞。
@MainActor
@Suite("ContainerCreationStore：超时后的确认段")
struct ContainerCreationStoreConfirmTests {

    private static let clock = Date(timeIntervalSince1970: 1_000_000)

    private func spec(_ name: String = "web") throws -> ContainerCreationSpec {
        try ContainerCreationSpec(
            name: ContainerName(name),
            image: #require(ImageRef("docker.io/library/alpine:latest")),
            volumeMounts: [],
            environment: []
        )
    }

    private func container(_ name: String = "web") throws -> Container {
        Container(
            id: try #require(ContainerID(name)),
            image: try #require(ImageRef("docker.io/library/alpine:latest")),
            state: .stopped,
            environment: []
        )
    }

    /// create 超时、带回 `op` 的 fake。
    private func timingOutClient(_ op: CreationOperationID) async -> FakeContainerRuntimeClient {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.outcomeUnknown(reason: "XPC call timed out", pending: op), for: .create)
        return client
    }

    private func store(_ client: FakeContainerRuntimeClient) -> ContainerCreationStore {
        ContainerCreationStore(client: client, now: { Self.clock })
    }

    @Test("超时 → 取回成功（只建不启）⇒ succeeded，不调 start")
    func lateSuccessWithoutStart() async throws {
        let op = CreationOperationID()
        let client = await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .success(try container()))
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: false)

        #expect(sut.phase == .succeeded(try #require(ContainerID("web"))))
        let calls = await client.calls
        #expect(calls.contains(.awaitPendingCreation(op)))
        #expect(!calls.contains { if case .start = $0 { true } else { false } })
    }

    @Test("G-D：超时 → 取回成功（创建并启动）⇒ 补上 start，succeeded")
    func lateSuccessRestoresStartIntent() async throws {
        let op = CreationOperationID()
        let client = await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .success(try container()))
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: true)

        let id = try #require(ContainerID("web"))
        #expect(sut.phase == .succeeded(id))
        let calls = await client.calls
        let awaitIndex = try #require(calls.firstIndex(of: .awaitPendingCreation(op)))
        let startIndex = try #require(calls.firstIndex(of: .start(id)))
        #expect(awaitIndex < startIndex)
    }

    @Test("超时 → 取回成功 → start 失败 ⇒ startFailed（保留、不回滚）")
    func lateSuccessThenStartFails() async throws {
        let op = CreationOperationID()
        let client = await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .success(try container()))
        await client.inject(.operationFailed(reason: "boom"), for: .start)
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: true)

        let id = try #require(ContainerID("web"))
        #expect(sut.phase == .failed(.startFailed(id, .operationFailed(reason: "boom"))))
        #expect(!(await client.calls).contains(.deleteContainer(id)))
    }

    @Test("超时 → 取回的是确定失败 ⇒ createFailed(那个错误)，不调 start")
    func lateFailure() async throws {
        let op = CreationOperationID()
        let client = await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .failure(.operationFailed(reason: "image not found")))
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: true)

        #expect(sut.phase == .failed(.createFailed(.operationFailed(reason: "image not found"))))
        #expect(!(await client.calls).contains { if case .start = $0 { true } else { false } })
    }

    @Test("超时 → 预算内仍没结果 ⇒ 放弃取回（abandon），终态 outcomeUnknown 且不再带 operationID")
    func stillUnknownAbandons() async throws {
        let op = CreationOperationID()
        let client = await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .failure(.outcomeUnknown(reason: "still running", pending: op)))
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: true)

        #expect(sut.phase == .failed(.createFailed(.outcomeUnknown(reason: "still running", pending: nil))))
        #expect((await client.calls).contains(.abandonPendingCreation(op)))
    }

    @Test("create 超时但没带 operationID ⇒ 不进确认段，直接 outcomeUnknown")
    func timeoutWithoutOperationSkipsConfirm() async throws {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.outcomeUnknown(reason: "t", pending: nil), for: .create)
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: false)

        #expect(sut.phase == .failed(.createFailed(.outcomeUnknown(reason: "t", pending: nil))))
        #expect(!(await client.calls).contains { if case .awaitPendingCreation = $0 { true } else { false } })
    }

    @Test("同名在途被挡 ⇒ 终态，不订阅别人的 operation")
    func creationInProgressIsTerminal() async throws {
        let client = FakeContainerRuntimeClient(containers: [])
        await client.inject(.creationInProgress(name: "web"), for: .create)
        let sut = store(client)

        await sut.submit(try spec(), startAfterCreate: true)

        #expect(sut.phase == .failed(.createFailed(.creationInProgress(name: "web"))))
        #expect(!(await client.calls).contains { if case .awaitPendingCreation = $0 { true } else { false } })
    }

    @Test("确认中：isBusy、submittedAt 已置；新的 submit 被单飞门拒")
    func confirmingRejectsResubmit() async throws {
        let op = CreationOperationID()
        let client = await timingOutClient(op)
        await client.setPendingCreationOutcome(op, .success(try container()))
        await client.holdPendingCreationAwaits()
        let sut = store(client)
        let spec = try spec()

        let first = Task { await sut.submit(spec, startAfterCreate: false) }
        while sut.phase != .confirming { await Task.yield() }

        #expect(sut.phase.isBusy)
        #expect(sut.submittedAt == Self.clock)

        // 不直接 await 第二次 submit：门若漏了，它会一路走到同样被扣住的 await，测试就互锁成「挂」而不是「红」。
        // 改看它有没有越过单飞门去调 list。
        let second = Task { await sut.submit(spec, startAfterCreate: false) }
        for _ in 0..<50 { await Task.yield() }
        #expect((await client.calls).filter { $0 == .list }.count == 1, "确认中的第二次 submit 越过了单飞门")

        await client.releasePendingCreationAwaits()
        #expect(await first.value)
        #expect(await second.value == false)
        #expect(sut.phase == .succeeded(try #require(ContainerID("web"))))
    }

    @Test("不变式：isBusy ⇔ submittedAt != nil（终态清空）")
    func submittedAtTracksBusy() async throws {
        let client = FakeContainerRuntimeClient(containers: [])
        let sut = store(client)
        #expect(!sut.phase.isBusy && sut.submittedAt == nil)

        await sut.submit(try spec(), startAfterCreate: false)

        #expect(!sut.phase.isBusy)
        #expect(sut.submittedAt == nil)
    }
}
