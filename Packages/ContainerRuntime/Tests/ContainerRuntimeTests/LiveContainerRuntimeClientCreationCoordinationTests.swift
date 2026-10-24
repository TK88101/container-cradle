import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// live client 怎么用 `CreationCoordinator`（Day 25，Plan 2026-10-22 §2.2 / T2）：占名在方法入口、
/// 超时带回 operationID、按它取回真实结果、同名后来者**不调上游**。状态机细节见 `CreationCoordinatorTests`。
@Suite("LiveContainerRuntimeClient：create / clone 的占名与取回结果")
struct LiveContainerRuntimeClientCreationCoordinationTests {

    private static let short: Duration = .milliseconds(50)

    private func client(
        upstream: FakeUpstreamClient,
        prober: any RuntimeProber = FakeRuntimeProber.up,
        createTimeout: Duration = Self.short
    ) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(upstream: upstream, paths: FakePathChecker(), prober: prober, createTimeout: createTimeout)
    }

    private func spec(_ name: String) throws -> ContainerCreationSpec {
        try ContainerCreationSpec(
            name: ContainerName(name),
            image: #require(ImageRef("docker.io/library/alpine:latest")),
            volumeMounts: [],
            environment: []
        )
    }

    /// 超时，返回带回的 operationID（没带回就记 issue）。
    private func createExpectingTimeout(_ sut: LiveContainerRuntimeClient, _ name: String) async throws -> CreationOperationID? {
        let spec = try spec(name)
        do {
            _ = try await sut.create(spec)
            Issue.record("expected outcomeUnknown")
        } catch {
            guard case .creation(.outcomeUnknown(_, let pending?)) = error else {
                Issue.record("got \(error)")
                return nil
            }
            return pending
        }
        return nil
    }

    @Test("T2-①：超时后同名再提交 ⇒ creationInProgress，上游 create 只被调了一次")
    func sameNameAfterTimeoutDoesNotReachUpstream() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream)

        _ = try await createExpectingTimeout(sut, "web")

        await #expect(throws: RuntimeError.creation(.inProgress(name: "web"))) {
            _ = try await sut.create(try spec("web"))
        }
        #expect(await upstream.count(.create("web")) == 1)
        await upstream.createGate.open()
    }

    @Test("T2-②⑧：超时 → 上游晚回话 → 按 operationID 取回真实 id；之后同名可再建")
    func awaitPendingCreationDeliversLateSuccess() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream)

        let op = try #require(try await createExpectingTimeout(sut, "web"))
        await upstream.createGate.open()

        let id = try await sut.awaitPendingCreation(op, within: .seconds(5))
        #expect(id == ContainerID("web"))

        _ = try await sut.create(try spec("web"))
        #expect(await upstream.count(.create("web")) == 2)
    }

    @Test("T2-⑧：上游晚回话但失败 ⇒ await 抛确定错误（不是 outcomeUnknown）")
    func awaitPendingCreationDeliversLateFailure() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        await upstream.setFailCreate(FakeUpstreamClient.Failure(label: "boom"))
        let sut = client(upstream: upstream)

        let op = try #require(try await createExpectingTimeout(sut, "web"))
        await upstream.createGate.open()

        do {
            _ = try await sut.awaitPendingCreation(op, within: .seconds(5))
            Issue.record("expected a throw")
        } catch {
            guard case .operationFailed = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test("T2-⑧：预算内仍没回话 ⇒ outcomeUnknown 带回同一个 operationID")
    func awaitPendingCreationOverBudgetKeepsOperation() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream)

        let op = try #require(try await createExpectingTimeout(sut, "web"))

        do {
            _ = try await sut.awaitPendingCreation(op, within: Self.short)
            Issue.record("expected a throw")
        } catch {
            guard case .creation(.outcomeUnknown(_, let pending)) = error else { Issue.record("got \(error)"); return }
            #expect(pending == op)
        }
        await upstream.createGate.open()
    }

    @Test("T2-⑧：未知 operationID ⇒ outcomeUnknown(pending: nil)，不冒认别人的结果")
    func awaitUnknownOperation() async {
        let sut = client(upstream: FakeUpstreamClient())
        do {
            _ = try await sut.awaitPendingCreation(CreationOperationID(), within: Self.short)
            Issue.record("expected a throw")
        } catch {
            guard case .creation(.outcomeUnknown(_, nil)) = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test("T2-③：不同名互不阻塞（第二个也真的发到上游）")
    func differentNamesBothReachUpstream() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream)

        _ = try await createExpectingTimeout(sut, "web-a")
        _ = try await createExpectingTimeout(sut, "web-b")

        #expect(await upstream.count(.create("web-a")) == 1)
        #expect(await upstream.count(.create("web-b")) == 1)
        await upstream.createGate.open()
    }

    @Test("T2-④：clone 在 fetch 源容器期间已占名 ⇒ 同名 fresh create 不调上游")
    func cloneReservesNameBeforeFetch() async throws {
        let snapshot = try Fixtures.openConnector()
        let source = try #require(ContainerID(snapshot.id))
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.getGate.close()
        let sut = client(upstream: upstream, createTimeout: .seconds(5))

        let clone = Task { try await sut.create(clonedFrom: source, name: ContainerName("web"), envOverride: nil) }
        while await upstream.count(.get(source.rawValue)) == 0 { await Task.yield() }

        await #expect(throws: RuntimeError.creation(.inProgress(name: "web"))) {
            _ = try await sut.create(try spec("web"))
        }
        #expect(await upstream.count(.create("web")) == 0)

        await upstream.getGate.open()
        #expect(try await clone.value == ContainerID("web"))
    }

    @Test("T2-⑤：clone 的 fetch 失败 ⇒ 名字随即释放")
    func cloneFetchFailureReleasesName() async throws {
        let snapshot = try Fixtures.openConnector()
        let source = try #require(ContainerID(snapshot.id))
        let upstream = FakeUpstreamClient(snapshots: [snapshot])
        await upstream.setFailGet(FakeUpstreamClient.Failure(label: "boom"))
        let sut = client(upstream: upstream, createTimeout: .seconds(5))

        await #expect(throws: RuntimeError.self) {
            _ = try await sut.create(clonedFrom: source, name: ContainerName("web"), envOverride: nil)
        }
        _ = try await sut.create(try spec("web"))
        #expect(sut.coordinator.counts.reservations == 0)
    }

    @Test("T2-⑦：client 的 copy 共享同一个 coordinator")
    func copiesShareReservations() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let original = client(upstream: upstream)
        let copy = original

        _ = try await createExpectingTimeout(original, "web")

        await #expect(throws: RuntimeError.creation(.inProgress(name: "web"))) {
            _ = try await copy.create(try spec("web"))
        }
        await upstream.createGate.open()
    }

    @Test("T2-⑥：在途数到上限 ⇒ 第 9 个不同名报 creationLimitReached，不调上游")
    func ninthConcurrentCreationIsRejected() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream)

        for index in 0..<CreationCoordinator.maxConcurrentCreations {
            _ = try await createExpectingTimeout(sut, "c\(index)")
        }
        await #expect(throws: RuntimeError.creation(.limitReached(limit: CreationCoordinator.maxConcurrentCreations))) {
            _ = try await sut.create(try spec("extra"))
        }
        #expect(await upstream.count(.create("extra")) == 0)
        await upstream.createGate.open()
    }

    @Test("T2-⑯：上游立即成功 / 立即失败 ⇒ 两张表都清空")
    func immediateOutcomesLeaveTablesEmpty() async throws {
        let upstream = FakeUpstreamClient()
        let sut = client(upstream: upstream, createTimeout: .seconds(5))

        _ = try await sut.create(try spec("ok"))
        await upstream.setFailCreate(FakeUpstreamClient.Failure(label: "boom"))
        await #expect(throws: RuntimeError.self) { _ = try await sut.create(try spec("bad")) }

        #expect(sut.coordinator.counts.reservations == 0)
        #expect(sut.coordinator.counts.operations == 0)
    }

    @Test("超时那一刻运行时已不在 ⇒ runtimeUnavailable（R14），且不留无人能领的结果")
    func timeoutWithRuntimeDownAbandonsOperation() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream, prober: FakeRuntimeProber.down)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            _ = try await sut.create(try spec("web"))
        }
        #expect(sut.coordinator.counts.operations == 0)
        #expect(sut.coordinator.counts.reservations == 1, "上游仍在跑，名字照样挡着")
        await upstream.createGate.open()
    }

    @Test("T2-⑪：同一 operation 的上游错误只映射一次")
    func upstreamErrorIsMappedOnce() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailCreate(FakeUpstreamClient.Failure(label: "boom"))
        let prober = CountingProber()
        let sut = client(upstream: upstream, prober: prober, createTimeout: .seconds(5))

        await #expect(throws: RuntimeError.self) { _ = try await sut.create(try spec("web")) }
        #expect(prober.probes == 1)
    }

    @Test("abandonPendingCreation：删掉待领结果，名字仍随上游调用结束才释放")
    func abandonRemovesOutcomeOnly() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.createGate.close()
        let sut = client(upstream: upstream)

        let op = try #require(try await createExpectingTimeout(sut, "web"))
        await sut.abandonPendingCreation(op)

        #expect(sut.coordinator.counts.operations == 0)
        await #expect(throws: RuntimeError.creation(.inProgress(name: "web"))) {
            _ = try await sut.create(try spec("web"))
        }
        await upstream.createGate.open()
    }
}
