import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

/// live client 的**序列**——幂等短路、mount 校验、失败回滚、错误映射。
///
/// 这些分支一条都不能是「豁免项」：R13 的生死线就长在里面，
/// 而 `LibprocProcessTable` 已经用一个 P1 证明过「被豁免的那一层最容易藏 bug」。
@Suite("LiveContainerRuntimeClient：拉起容器的那段序列")
struct LiveContainerRuntimeClientTests {

    private func client(
        upstream: FakeUpstreamClient,
        existingPaths: Set<String> = [],
        prober: FakeRuntimeProber = .up,
        timeout: Duration = .seconds(5)
    ) -> LiveContainerRuntimeClient {
        LiveContainerRuntimeClient(
            upstream: upstream,
            paths: FakePathChecker(existing: existingPaths),
            prober: prober,
            timeout: timeout
        )
    }

    private func id(_ raw: String) throws -> ContainerID {
        try #require(ContainerID(raw))
    }

    // MARK: - ★★ R13：mount 源未就绪

    /// **这个 App 的生死线。**
    ///
    /// 外置盘还没挂上（Mac 刚重启）→ 必须抛 `.mountSourceUnavailable`。
    /// 抛成 `.operationFailed` 的话：判 `.transient` → 计入熔断 → 退避 1→2→4→8→16 秒 →
    /// **31 秒后熔断放弃**，而外置盘要几分钟才就绪。supervisor 死在它唯一该活着的那一刻。
    @Test("virtiofs mount 源不存在 → .mountSourceUnavailable（不是 .operationFailed）")
    func missingMountSourceThrowsMountError() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        let subject = client(upstream: upstream)                 // 路径一个都不存在
        let target = try id("needs-external-disk")

        await #expect(throws: RuntimeError.mountSourceUnavailable(
            path: "/Volumes/ExternalDisk/container-data"
        )) {
            try await subject.start(id: target)
        }
    }

    /// ★★★ **把 Day 4 / Day 5 / Day 6 三天的链子钉成一根。**
    ///
    /// live client 抛出的那个错误，经 `FailureClassification` 之后必须落在
    /// `.environmentNotReady`——**永不计入熔断**的那一档。
    ///
    /// 这条断言跨了两个 package。它存在的理由是 CLAUDE.md 那句话：
    /// 「这条链子只要有一环接错，整条就断了，且全绿」。单独测 live client「抛了 mount 错误」
    /// 是不够的——真正要守的不变式是**最终不会熔断**。
    @Test("R13 全链：mount 错误 → FailureKind.environmentNotReady（永不熔断）")
    func mountErrorNeverCountsTowardCircuitBreaker() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        let subject = client(upstream: upstream)

        let target = try id("needs-external-disk")

        do {
            try await subject.start(id: target)
            Issue.record("应当抛出 mountSourceUnavailable")
        } catch {
            #expect(
                FailureKind(from: error) == .environmentNotReady,
                """
                R13 断了：mount 源未就绪被判成了 \(FailureKind(from: error))。
                只要它不是 .environmentNotReady，supervisor 就会在 31 秒后熔断放弃——
                而那正是「Mac 重启后外置盘还没挂上」的时刻，也就是这个 App 唯一该活着的时刻。
                """
            )
        }
    }

    /// mount 校验失败时**不该**回滚 stop：容器根本还没 bootstrap。
    ///
    /// 这条同时守着一个结构约束——校验必须在 `do` 块**外面**。
    /// 一旦有人把它挪进 `do`，`.mountSourceUnavailable` 就会落进 catch 被重新包装
    /// （R13 当场断掉），而这条测试会因为多出一个 `.stop` 调用而变红。
    @Test("mount 校验失败 → 不回滚（还没起，没什么可回滚的）")
    func doesNotRollBackWhenMountCheckFails() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        let subject = client(upstream: upstream)

        try? await subject.start(id: try id("needs-external-disk"))

        let calls = await upstream.calls
        #expect(!calls.contains(.stop("needs-external-disk")), "不该回滚：容器还没被 bootstrap")
        #expect(!calls.contains(.launch("needs-external-disk")), "不该 bootstrap：mount 都没就绪")
    }

    /// 外置盘挂上了 → 校验通过 → 正常起。
    @Test("virtiofs mount 源存在 → 正常 bootstrap")
    func startsWhenMountSourceExists() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        let subject = client(
            upstream: upstream,
            existingPaths: ["/Volumes/ExternalDisk/container-data"]
        )

        try await subject.start(id: try id("needs-external-disk"))

        let calls = await upstream.calls
        #expect(calls.contains(.launch("needs-external-disk")))
    }

    /// **volume mount 不该被校验。** fixture 里那个容器同时有一个 volume mount，
    /// 它的 source 指向一个不存在的 `.img` 路径——若我们连它一起校验，
    /// 容器会因为一个**根本不需要宿主路径就绪**的 mount 而永远起不来。
    ///
    /// （上游只对 `isVirtiofs` 的 mount 做校验，已核实源码。）
    @Test("volume mount 不参与校验：只有 virtiofs 才看宿主路径")
    func onlyVirtiofsMountsAreChecked() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        // 只把 virtiofs 那条的源路径准备好；volume 那条的 .img 路径**不存在**。
        let subject = client(
            upstream: upstream,
            existingPaths: ["/Volumes/ExternalDisk/container-data"]
        )

        // 若 volume mount 也被校验，这里会抛 mountSourceUnavailable。
        try await subject.start(id: try id("needs-external-disk"))

        #expect(await upstream.calls.contains(.launch("needs-external-disk")))
    }

    // MARK: - 幂等

    /// supervisor 会重复下达 start（轮询间隔内容器可能还没起来，下一轮又看见它 stopped）。
    /// 「已经在跑」必须**静默成功且不 bootstrap**——官方 CLI 自己就这么短路的。
    @Test("已在运行 → 静默成功，且不 bootstrap")
    func startIsIdempotentWhenRunning() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.openConnector()])   // running
        let subject = client(upstream: upstream)

        try await subject.start(id: try id("open-connector"))

        let calls = await upstream.calls
        #expect(calls == [.get("open-connector")], "短路了就不该再有任何调用")
    }

    @Test("已停止 → stop 静默成功，且不打 XPC")
    func stopIsIdempotentWhenStopped() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])  // stopped
        let subject = client(upstream: upstream)

        try await subject.stop(id: try id("needs-external-disk"))

        #expect(await upstream.calls == [.get("needs-external-disk")])
    }

    // MARK: - 失败回滚

    /// bootstrap 失败 → **必须回滚 `stop`**，否则留下半启动状态。
    @Test("bootstrap 失败 → 回滚 stop")
    func rollsBackWhenLaunchFails() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        await upstream.setFailLaunch(FakeUpstreamClient.Failure(label: "bootstrap 炸了"))

        let subject = client(
            upstream: upstream,
            existingPaths: ["/Volumes/ExternalDisk/container-data"]
        )

        let target = try id("needs-external-disk")
        await #expect(throws: RuntimeError.self) {
            try await subject.start(id: target)
        }

        #expect(await upstream.calls.contains(.stop("needs-external-disk")), "半启动状态必须被回滚")
    }

    /// 回滚本身失败也不能盖掉真正的失败原因。
    @Test("回滚失败 → 仍抛原始失败，不抛回滚的失败")
    func rollbackFailureDoesNotMaskOriginalError() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        await upstream.setFailLaunch(FakeUpstreamClient.Failure(label: "原始失败"))
        await upstream.setFailStop(FakeUpstreamClient.Failure(label: "回滚也失败"))

        let subject = client(
            upstream: upstream,
            existingPaths: ["/Volumes/ExternalDisk/container-data"]
        )

        let target = try id("needs-external-disk")

        do {
            try await subject.start(id: target)
            Issue.record("应当抛错")
        } catch {
            guard case .operationFailed(let reason) = error else {
                Issue.record("期望 .operationFailed，得到 \(error)")
                return
            }
            #expect(reason.contains("原始失败"))
            #expect(!reason.contains("回滚也失败"))
        }
    }

    /// ★ **codex review 抓到的 P1。**
    ///
    /// bootstrap 失败 → 走回滚 `stop` → 而这一句**当时没套超时**。
    /// XPC 若在回滚上挂死，`try?` 吞得掉错误，**吞不掉挂死**：`start()` 永不返回，
    /// supervisor 当场冻住（R5）。而且它发生在最坏的位置——bootstrap 刚失败的回滚路径，
    /// 恰恰是 R13 场景（外置盘没挂上）的高频路径。
    ///
    /// 用**不响应取消**的 hang 来测（`Task.sleep` 测不出来：它响应取消，
    /// 会让一个没有超时能力的实现照样变绿）。
    @Test("回滚的 stop 挂死 → start 仍在超时后返回，不冻住", .timeLimit(.minutes(1)))
    func rollbackDoesNotHangWhenStopHangs() async throws {
        let upstream = FakeUpstreamClient(snapshots: [try Fixtures.needsExternalDisk()])
        await upstream.setFailLaunch(FakeUpstreamClient.Failure(label: "bootstrap 炸了"))
        await upstream.setHangStop(true)                     // 回滚的 XPC 永不回话

        let subject = client(
            upstream: upstream,
            existingPaths: ["/Volumes/ExternalDisk/container-data"],
            timeout: .milliseconds(20)
        )
        let target = try id("needs-external-disk")

        // 回滚超时后，仍要抛出**原始**失败（不是超时，也不是回滚的错）。
        await #expect(throws: RuntimeError.self) {
            try await subject.start(id: target)
        }

        #expect(await upstream.calls.contains(.stop("needs-external-disk")), "回滚该被尝试过")
    }

    // MARK: - list

    @Test("list：真机 fixture → domain 列表")
    func listsContainers() async throws {
        let upstream = FakeUpstreamClient(snapshots: try Fixtures.snapshots("snapshots"))
        let subject = client(upstream: upstream)

        let containers = try await subject.list()

        #expect(containers.count == 1)
        #expect(containers.first?.id.rawValue == "open-connector")
    }

    /// 一个容器映射不出来 → **整个 list 失败**，不返回「少了一个」的列表。
    @Test("list：有容器映射不出来 → 整体失败，不静默丢弃")
    func listFailsClosedOnUnmappableContainer() async throws {
        var broken = try Fixtures.openConnector()
        broken.configuration.image = ImageDescription(
            reference: "  ",
            descriptor: broken.configuration.image.descriptor
        )

        let upstream = FakeUpstreamClient()
        await upstream.setListResult([broken])
        let subject = client(upstream: upstream)

        await #expect(throws: RuntimeError.self) {
            try await subject.list()
        }
    }

    // MARK: - R14：运行时死活以进程表为准

    /// XPC 报错 + 进程表说 apiserver 不在 → `.runtimeUnavailable`。
    @Test("XPC 失败且 prober 说 down → .runtimeUnavailable")
    func reportsRuntimeUnavailableWhenProberSaysDown() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailList(FakeUpstreamClient.Failure(label: "XPC connection invalid"))

        let subject = client(upstream: upstream, prober: .down)

        await #expect(throws: RuntimeError.runtimeUnavailable) {
            try await subject.list()
        }
    }

    /// ★ **codex review 第二轮抓到的 P2。**
    ///
    /// XPC 的超时窗口**之内** apiserver 死掉（进程消失）：我们看到的是「超时」，
    /// 而真相是「运行时没了」。
    ///
    /// 超时判断原本排在 probe **前面**，于是这种情况被判成 `.operationFailed` → `.transient`
    /// → **计入熔断**。但 `FailureClassification` 的原则是：**运行时自己死了不是容器 crashloop
    /// 的证据**。判错档位，apiserver 抖几下 supervisor 就永久放弃了。
    ///
    /// → 进程表必须先跑。它是唯一权威（R14），超时不能替它回答。
    @Test("超时 + prober 说 down → .runtimeUnavailable（不是 transient，不计熔断）")
    func timeoutWithDeadRuntimeIsRuntimeUnavailable() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setHangList(true)                     // XPC 不回话 → 触发超时

        let subject = client(
            upstream: upstream,
            prober: .down,                                   // 而进程表说 apiserver 已经没了
            timeout: .milliseconds(20)
        )

        do {
            _ = try await subject.list()
            Issue.record("应当抛错")
        } catch {
            #expect(error == .runtimeUnavailable, "超时不该替进程表回答『运行时死没死』")
            #expect(
                FailureKind(from: error) == .environmentNotReady,
                "运行时死了不是 crashloop 的证据，不能计入熔断"
            )
        }
    }

    /// **同一个错误**，进程表说 apiserver 还在 → **不是** `.runtimeUnavailable`。
    ///
    /// 这一对测试是 R14 的核心：判定权在进程表，不在错误码。
    /// 少了这一条，一个「XPC 报错就当运行时挂了」的实现也能让上一条变绿——
    /// 然后 supervisor 会因为一次抖动去重启一堆本来好好的容器。
    @Test("同样的 XPC 失败，但 prober 说 running → 不是 runtimeUnavailable")
    func doesNotBlameRuntimeWhenProberSaysUp() async throws {
        let upstream = FakeUpstreamClient()
        await upstream.setFailList(FakeUpstreamClient.Failure(label: "XPC connection invalid"))

        let subject = client(upstream: upstream, prober: .up)

        do {
            _ = try await subject.list()
            Issue.record("应当抛错")
        } catch {
            #expect(error != .runtimeUnavailable, "进程表说 apiserver 还在，不该赖运行时")
            #expect(FailureKind(from: error) == .transient)
        }
    }
}
