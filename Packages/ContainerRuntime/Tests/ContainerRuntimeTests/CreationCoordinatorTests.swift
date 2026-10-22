import ContainerCore
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntime

/// `CreationCoordinator` 的状态机（Day 25，Plan 2026-10-22 §2.2）。接线（live client 怎么用它）见 `LiveContainerRuntimeClientCreationCoordinationTests`。
///
/// 「上游 create」在这里是一段可放行的 work：闸门关着 = 上游还没回话（不响应取消，同 XPC）。
@Suite("CreationCoordinator：占名、取结果、放弃")
struct CreationCoordinatorTests {

    typealias Outcome = CreationCoordinator.Outcome

    private static let budget: Duration = .seconds(5)
    private static let short: Duration = .milliseconds(50)

    private func id(_ raw: String) throws -> ContainerID {
        try #require(ContainerID(raw))
    }

    /// 一段停在闸门后的 work，放行后回 `outcome`。
    private func gatedWork(_ gate: TestGate, _ outcome: Outcome) -> @Sendable () async -> Outcome {
        { await gate.passThrough(); return outcome }
    }

    private func closedGate() async -> TestGate {
        let gate = TestGate()
        await gate.close()
        return gate
    }

    /// coordinator 不交出 Task（Day 25 simcodex R1），测试按可观测状态等：名字都已释放
    /// （`finish` 在同一把锁里放名字并把在途改成待领，所以 reservations 归零即无在途）。
    private func waitUntilIdle(_ sut: CreationCoordinator) async {
        await waitUntil { sut.counts.reservations == 0 }
    }

    private static func success(_ raw: String) -> Outcome {
        ContainerID(raw).map { .success($0) } ?? .failure(.operationFailed(reason: "bad id"))
    }

    // MARK: - 占名

    @Test("同名在途 ⇒ 第二次被挡（creationInProgress），不跑它的 work")
    func sameNameIsRejectedWhileInFlight() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        _ = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        let secondRan = Counter()
        #expect(throws: RuntimeError.creationInProgress(name: "web")) {
            _ = try sut.start(name: "web") { secondRan.increment(); return Self.success("web") }
        }
        #expect(secondRan.value == 0)
        await gate.open()
    }

    @Test("不同名互不阻塞")
    func differentNamesDoNotBlock() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        _ = try sut.start(name: "a", work: gatedWork(gate, Self.success("a")))
        _ = try sut.start(name: "b", work: gatedWork(gate, Self.success("b")))
        #expect(sut.counts.reservations == 2)
        await gate.open()
    }

    @Test("work 结束 ⇒ 同名可再占")
    func nameIsFreedWhenWorkFinishes() async throws {
        let sut = CreationCoordinator()
        _ = try sut.start(name: "web") { Self.success("web") }
        await waitUntilIdle(sut)

        _ = try sut.start(name: "web") { Self.success("web") }
    }

    @Test("在途达到上限 ⇒ 下一个不同名被挡（creationLimitReached），不跑它的 work")
    func limitRejectsNextCreation() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        for index in 0..<CreationCoordinator.maxConcurrentCreations {
            _ = try sut.start(name: "c\(index)", work: gatedWork(gate, .failure(.operationFailed(reason: "x"))))
        }

        let ran = Counter()
        #expect(throws: RuntimeError.creationLimitReached(limit: CreationCoordinator.maxConcurrentCreations)) {
            _ = try sut.start(name: "extra") { ran.increment(); return .failure(.operationFailed(reason: "x")) }
        }
        #expect(ran.value == 0)
        #expect(sut.counts.reservations == CreationCoordinator.maxConcurrentCreations)
        await gate.open()
    }

    @Test("同名优先于上限：同名在途时报 creationInProgress 而不是 limit")
    func sameNameWinsOverLimit() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        for index in 0..<CreationCoordinator.maxConcurrentCreations {
            _ = try sut.start(name: "c\(index)", work: gatedWork(gate, .failure(.operationFailed(reason: "x"))))
        }
        #expect(throws: RuntimeError.creationInProgress(name: "c0")) {
            _ = try sut.start(name: "c0") { .failure(.operationFailed(reason: "x")) }
        }
        await gate.open()
    }

    // MARK: - 线性化（codex R6-P1）

    @Test("work 立即完成：完成后没有永不完成的在途记录，名字已释放")
    func immediateCompletionLeavesNoInFlight() async throws {
        let sut = CreationCoordinator()
        let op = try sut.start(name: "web") { Self.success("web") }
        await waitUntilIdle(sut)

        #expect(sut.counts.reservations == 0)
        #expect(sut.counts.inFlight == 0)
        sut.abandon(op)
        #expect(sut.counts.operations == 0)
    }

    // MARK: - 取结果（按 operationID，不按名字）

    @Test("在途 → 主人 await → 拿到结果并消费")
    func awaitDeliversInFlightOutcome() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        async let result = sut.awaitOutcome(op, within: Self.budget)
        await gate.open()

        #expect(await result == .delivered(Self.success("web")))
        #expect(sut.counts.operations == 0)
    }

    @Test("在途失败 → await 交出确定错误")
    func awaitDeliversInFlightFailure() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, .failure(.operationFailed(reason: "boom"))))

        async let result = sut.awaitOutcome(op, within: Self.budget)
        await gate.open()

        #expect(await result == .delivered(.failure(.operationFailed(reason: "boom"))))
    }

    @Test("超预算 ⇒ stillRunning，条目不删、可再 await")
    func awaitOverBudgetCanRetry() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        #expect(await sut.awaitOutcome(op, within: Self.short) == .stillRunning)

        async let again = sut.awaitOutcome(op, within: Self.budget)
        await gate.open()
        #expect(await again == .delivered(Self.success("web")))
    }

    @Test("被取消的 await ⇒ stillRunning，不删、可再 await")
    func cancelledAwaitCanRetry() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        let waiter = Task { await sut.awaitOutcome(op, within: Self.budget) }
        waiter.cancel()
        #expect(await waiter.value == .stillRunning)

        async let again = sut.awaitOutcome(op, within: Self.budget)
        await gate.open()
        #expect(await again == .delivered(Self.success("web")))
    }

    @Test("已完成（done）→ await 直接交出并消费；再 await ⇒ unavailable")
    func awaitDeliversDoneOnce() async throws {
        let sut = CreationCoordinator()
        let op = try sut.start(name: "web") { Self.success("web") }
        await waitUntilIdle(sut)

        #expect(await sut.awaitOutcome(op, within: Self.budget) == .delivered(Self.success("web")))
        #expect(await sut.awaitOutcome(op, within: Self.budget) == .unavailable)
    }

    @Test("未知 operationID ⇒ unavailable")
    func unknownOperationIsUnavailable() async {
        let sut = CreationCoordinator()
        #expect(await sut.awaitOutcome(CreationOperationID(), within: Self.short) == .unavailable)
    }

    @Test("codex R2-P0 / R3-P1：A 完成 → 同名 B 占名 → A 晚 await ⇒ 拿到 A 自己的结果，不是 B 的")
    func lateOwnerGetsItsOwnOutcomeAfterSameNameReuse() async throws {
        let sut = CreationCoordinator()
        let opA = try sut.start(name: "web") { .failure(.operationFailed(reason: "A")) }
        await waitUntilIdle(sut)

        let gateB = await closedGate()
        let opB = try sut.start(name: "web", work: gatedWork(gateB, Self.success("web")))
        #expect(opA != opB)

        #expect(await sut.awaitOutcome(opA, within: Self.budget) == .delivered(.failure(.operationFailed(reason: "A"))))
        await gateB.open()
    }

    // MARK: - 放弃（所有权结束，不是 TTL）

    @Test("abandon 不放名字：work 仍在跑时同名照样被挡")
    func abandonKeepsReservation() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        sut.abandon(op)

        #expect(throws: RuntimeError.creationInProgress(name: "web")) {
            _ = try sut.start(name: "web") { Self.success("web") }
        }
        await gate.open()
    }

    @Test("abandon 后 work 晚完成 ⇒ 不留待领结果，名字随 work 结束释放")
    func lateCompletionAfterAbandonIsDropped() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        sut.abandon(op)
        await gate.open()
        await waitUntilIdle(sut)

        #expect(sut.counts.operations == 0)
        #expect(sut.counts.reservations == 0)
        #expect(await sut.awaitOutcome(op, within: Self.short) == .unavailable)
    }

    @Test("codex R6-P1：await 已在等 work 时被 abandon ⇒ 结果不交付")
    func abandonDuringAwaitWithholdsOutcome() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        let waiter = Task { await sut.awaitOutcome(op, within: Self.budget) }
        try await Task.sleep(for: .milliseconds(30))   // 让 waiter 进入等待
        sut.abandon(op)
        await gate.open()

        #expect(await waiter.value == .unavailable)
    }

    @Test("两个并发 await：只有一个拿到结果（严格单消费）")
    func concurrentAwaitsDeliverOnce() async throws {
        let sut = CreationCoordinator()
        let gate = await closedGate()
        let op = try sut.start(name: "web", work: gatedWork(gate, Self.success("web")))

        async let first = sut.awaitOutcome(op, within: Self.budget)
        async let second = sut.awaitOutcome(op, within: Self.budget)
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()

        let results = await [first, second]
        #expect(results.filter { $0 == .delivered(Self.success("web")) }.count == 1)
        #expect(results.filter { $0 == .unavailable }.count == 1)
    }

    @Test("abandon 幂等，对未知 id 无副作用")
    func abandonIsIdempotent() async throws {
        let sut = CreationCoordinator()
        let op = try sut.start(name: "web") { Self.success("web") }
        await waitUntilIdle(sut)

        sut.abandon(CreationOperationID())
        #expect(sut.counts.operations == 1)
        sut.abandon(op)
        sut.abandon(op)
        #expect(sut.counts.operations == 0)
    }

    // MARK: - 上界

    @Test("待领结果超过上限 ⇒ 淘汰最早完成的那条，已消费的不占名额")
    func doneOutcomesAreBounded() async throws {
        let sut = CreationCoordinator()
        var ops: [CreationOperationID] = []
        for index in 0...CreationCoordinator.maxRetainedOutcomes {
            let op = try sut.start(name: "c\(index)") { .failure(.operationFailed(reason: "\(index)")) }
            await waitUntilIdle(sut)
            ops.append(op)
        }

        #expect(sut.counts.operations == CreationCoordinator.maxRetainedOutcomes)
        #expect(await sut.awaitOutcome(ops[0], within: Self.short) == .unavailable)
        #expect(
            await sut.awaitOutcome(ops[1], within: Self.short)
                == .delivered(.failure(.operationFailed(reason: "1")))
        )
        // 消费掉一条后，再来一条不会挤掉别人
        let extra = try sut.start(name: "extra") { .failure(.operationFailed(reason: "extra")) }
        await waitUntilIdle(sut)
        #expect(sut.counts.operations == CreationCoordinator.maxRetainedOutcomes)
        #expect(await sut.awaitOutcome(ops[2], within: Self.short) != .unavailable)
        #expect(await sut.awaitOutcome(extra, within: Self.short) != .unavailable)
    }

    @Test("上界：在途挂满 + 待领挂满时，两张表都不超过上限")
    func tablesStayBounded() async throws {
        let sut = CreationCoordinator()
        for index in 0..<(CreationCoordinator.maxRetainedOutcomes + 4) {
            _ = try sut.start(name: "d\(index)") { .failure(.operationFailed(reason: "x")) }
            await waitUntilIdle(sut)
        }
        let gate = await closedGate()
        for index in 0..<CreationCoordinator.maxConcurrentCreations {
            _ = try sut.start(name: "h\(index)", work: gatedWork(gate, .failure(.operationFailed(reason: "x"))))
        }
        _ = try? sut.start(name: "overflow") { .failure(.operationFailed(reason: "x")) }

        #expect(sut.counts.reservations <= CreationCoordinator.maxConcurrentCreations)
        #expect(
            sut.counts.operations
                <= CreationCoordinator.maxConcurrentCreations + CreationCoordinator.maxRetainedOutcomes
        )
        await gate.open()
    }
}

/// 线程安全计数器（同步 work 闭包里用）。
final class Counter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}
