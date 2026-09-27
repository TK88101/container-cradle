import Foundation
import Testing

@testable import ContainerCore

/// Day 22 R2 F：App 退出前的有界交接（`Supervisor.settleBeforeStop`）。
@Suite("Supervisor.settleBeforeStop：退出前把新一代交接完，但绝不冻住退出")
struct SupervisorSettleTests {

    /// 永不返回、也**不响应取消**的探测（CLAUDE.md ★：拿会响应取消的 `Task.sleep` 当挂死，没有超时能力的实现也会变绿）。
    struct HangingProber: RuntimeProber {
        func probe() async -> ProbeResult {
            await withUnsafeContinuation { (_: UnsafeContinuation<ProbeResult, Never>) in }
        }
    }

    static func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    static func supervisor(prober: any RuntimeProber, client: FakeContainerRuntimeClient) -> Supervisor {
        Supervisor(
            prober: prober,
            engine: WhitelistReconcileEngine(
                client: client,
                whitelist: FixedWhitelist(list: [WhitelistEntry(id: id("a"))])
            ),
            backoff: FixedBackoff(10),
            clock: ManualClock()
        )
    }

    @Test("运行时刚被起回来（新一代）→ 探到、reconcile 跑完才返回 true：白名单容器已被拉起")
    func handsOffNewGeneration() async {
        let prober = FakeRuntimeProber(.down)
        let client = FakeContainerRuntimeClient(containers: [
            Container(id: Self.id("a"), image: ImageRef("busybox:1")!, state: .stopped, environment: []),
        ])
        let supervisor = Self.supervisor(prober: prober, client: client)
        await supervisor.step()                                          // 升级途中：运行时 down
        await prober.set(.running(RuntimeGeneration(pid: 200, startTime: 2_000)))   // 收尾把它起回来了

        #expect(await supervisor.settleBeforeStop(within: .seconds(10)))
        #expect(await client.calls == [.start(Self.id("a"))])
    }

    /// R3 P2-3：`forceReconcile` 读的是 stop 之后的新 epoch，epoch 挡不住它——必须另有「已停」的判据。
    @Test("stop() 之后的 forceReconcile 不再起容器")
    func forceReconcileAfterStopIsIgnored() async {
        let prober = FakeRuntimeProber(.running(RuntimeGeneration(pid: 100, startTime: 1_000)))
        let client = FakeContainerRuntimeClient(containers: [
            Container(id: Self.id("a"), image: ImageRef("busybox:1")!, state: .stopped, environment: []),
        ])
        let supervisor = Self.supervisor(prober: prober, client: client)
        await supervisor.step()            // 冷启动：运行时在跑 → baseline
        await supervisor.stop()
        await supervisor.forceReconcile()  // 退出途中迟到的「请 reconcile」
        await supervisor.awaitReconcile()
        #expect(await client.calls.isEmpty)
    }

    // MARK: - R5：刚把运行时起回来的调用方请 reconcile

    static func stoppedA() -> FakeContainerRuntimeClient {
        FakeContainerRuntimeClient(containers: [
            Container(id: id("a"), image: ImageRef("busybox:1")!, state: .stopped, environment: []),
        ])
    }

    @Test("对照：supervisor 还停在 runtimeDown 时单独 forceReconcile → 被拒（菜单里「没有运行时可拉」），什么都不拉")
    func forceReconcileWhileDownIsRejected() async {
        let prober = FakeRuntimeProber(.down)
        let client = Self.stoppedA()
        let supervisor = Self.supervisor(prober: prober, client: client)
        await supervisor.step()
        await prober.set(.running(RuntimeGeneration(pid: 200, startTime: 2_000)))   // 更新器刚 system start 完
        await supervisor.forceReconcile()
        await supervisor.awaitReconcile()
        #expect(await client.calls.isEmpty)
    }

    @Test("刚起回运行时就请 reconcile：先探一次再下达 → 新一代由边沿触发 reconcile，白名单被拉起")
    func reconcileManagedNowProbesFirst() async {
        let prober = FakeRuntimeProber(.down)
        let client = Self.stoppedA()
        let supervisor = Self.supervisor(prober: prober, client: client)
        await supervisor.step()
        await prober.set(.running(RuntimeGeneration(pid: 200, startTime: 2_000)))
        await supervisor.reconcileManagedNow()
        await supervisor.awaitReconcile()
        #expect(await client.calls == [.start(Self.id("a"))])
    }

    @Test("冷启动 baseline（同一代、没有边沿）时照常强制 reconcile")
    func reconcileManagedNowOnBaseline() async {
        let prober = FakeRuntimeProber(.running(RuntimeGeneration(pid: 100, startTime: 1_000)))
        let client = Self.stoppedA()
        let supervisor = Self.supervisor(prober: prober, client: client)
        await supervisor.step()                       // 冷启动：baseline，不 reconcile
        #expect(await client.calls.isEmpty)
        await supervisor.reconcileManagedNow()
        await supervisor.awaitReconcile()
        #expect(await client.calls == [.start(Self.id("a"))])
    }

    @Test("stop() 之后 reconcileManagedNow 不探测、不拉")
    func reconcileManagedNowAfterStopIsIgnored() async {
        let prober = FakeRuntimeProber(.down)
        let client = Self.stoppedA()
        let supervisor = Self.supervisor(prober: prober, client: client)
        await supervisor.step()
        await supervisor.stop()
        await prober.set(.running(RuntimeGeneration(pid: 200, startTime: 2_000)))
        await supervisor.reconcileManagedNow()
        await supervisor.awaitReconcile()
        #expect(await client.calls.isEmpty)
    }

    @Test("探测挂死 → 时限一到就返回 false（不冻住退出），之后 stop() 照常")
    func hangingProbeDoesNotFreezeQuit() async {
        let supervisor = Self.supervisor(prober: HangingProber(), client: FakeContainerRuntimeClient(containers: []))
        let started = ContinuousClock.now
        let settled = await supervisor.settleBeforeStop(within: .milliseconds(300))
        #expect(!settled)
        #expect(ContinuousClock.now - started < .seconds(5))
        await supervisor.stop()
        #expect(await supervisor.isProbing == false)
    }
}
