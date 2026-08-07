import Testing

@testable import ContainerCore

/// T9.2：`ImagePullStore` 态机 + 取消重入令牌（本轮最高风险）。
///
/// 核心命题（codex #2/#3）：**取消后旧代 `runPull` 的回写一律被 `pullGeneration` 拦**——即使 Fake
/// 主动 finish 旧流（模拟后台迟到完成），终态只能 idle、不误报 done、不调成功 `onCompleted`。
/// 断言不变式（state / 计数），不断言下游时序（本仓「测副作用=跟调度器赛跑」纪律）。
@MainActor
@Suite("ImagePullStore 态机与取消令牌")
struct ImagePullStoreTests {

    /// onCompleted 计数器（@MainActor，测试同 isolation）。
    @MainActor final class Bumper { var count = 0 }

    private func progress(_ items: Int, _ total: Int) -> PullProgress {
        PullProgress(phase: "Fetching", items: items, totalItems: total, bytes: nil, totalBytes: nil)
    }

    private func ref(_ s: String = "nginx:latest") -> ImageRef { ImageRef(s)! }

    private func pullCallCount(_ calls: [FakeContainerRuntimeClient.Call]) -> Int {
        calls.filter { if case .pullImage = $0 { return true } else { return false } }.count
    }

    // MARK: - 成功路径

    @Test("pull 成功：终态 done + onCompleted 恰一次 + pullImage 调一次")
    func pullSucceeds() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullProgress([progress(1, 3), progress(3, 3)])
        let bumper = Bumper()
        let store = ImagePullStore(client: fake) { bumper.count += 1 }
        let r = ref()

        store.pull(r)
        await store.awaitCurrentTaskForTests()

        #expect(store.state == .done(reference: r))
        #expect(bumper.count == 1)
        #expect(pullCallCount(await fake.calls) == 1)
    }

    // MARK: - 单飞门（codex #11）

    @Test("pulling 中再 pull 被拒：pullImage 只调一次")
    func rejectDuringPulling() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullProgress([progress(1, 1)])
        let store = ImagePullStore(client: fake) {}

        store.pull(ref("a:1"))       // 同步置 pulling(nil) + 起 task
        store.pull(ref("b:2"))       // 同步：state 是 pulling → 拒（不起 task、不调 pullImage）
        await store.awaitCurrentTaskForTests()

        #expect(pullCallCount(await fake.calls) == 1)
    }

    @Test("done 后可直接再 pull（不必 dismiss）：pullImage 调两次")
    func canRepullAfterDone() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullProgress([progress(1, 1)])
        let store = ImagePullStore(client: fake) {}

        store.pull(ref("a:1"))
        await store.awaitCurrentTaskForTests()
        #expect(store.state == .done(reference: ref("a:1")))

        store.pull(ref("b:2"))       // done 后允许发起
        await store.awaitCurrentTaskForTests()
        #expect(store.state == .done(reference: ref("b:2")))
        #expect(pullCallCount(await fake.calls) == 2)
    }

    // MARK: - 失败通道

    @Test("建流失败 → failed(.setup)")
    func setupFailure() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.runtimeUnavailable, for: .pullImage)
        let store = ImagePullStore(client: fake) {}
        let r = ref()

        store.pull(r)
        await store.awaitCurrentTaskForTests()

        #expect(store.state == .failed(reference: r, kind: .setup(.runtimeUnavailable)))
    }

    @Test("流内失败 → failed(.stream)")
    func streamFailure() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullStreamError(.runtimeUnavailable)   // 普通流 yield 完 finish(throwing:)，无赛跑
        let store = ImagePullStore(client: fake) {}
        let r = ref()

        store.pull(r)
        await store.awaitCurrentTaskForTests()

        guard case .failed(let failedRef, .stream) = store.state else {
            Issue.record("expected failed(.stream), got \(store.state)")
            return
        }
        #expect(failedRef == r)
    }

    // MARK: - 取消重入令牌（★核心，codex #2/#3）

    @Test("取消后旧流迟到 finish 被令牌拦：终态 idle、不 done、不调成功 onCompleted")
    func cancelBlocksLateCompletion() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullStreamSuspends(true)
        await fake.setPullProgress([progress(1, 2)])
        let bumper = Bumper()
        let store = ImagePullStore(client: fake) { bumper.count += 1 }

        store.pull(ref())                        // state → pulling
        await fake.awaitPullStreamReadyForTests() // 等建流就绪，避免赛跑（不靠 task.cancel 时序运气）
        store.cancel()                           // gen++，旧代失效；state → cancellingForeground（可观测）

        if case .cancellingForeground = store.state {} else {
            Issue.record("expected cancellingForeground after cancel, got \(store.state)")
        }

        await fake.finishPullStream()            // 旧流「后台迟到完成」——runPull 想置 done → 被 gen 拦
        await store.awaitCurrentTaskForTests()   // 收尾 task 落 idle

        #expect(store.state == .idle)            // 不是 done
        #expect(bumper.count == 0)               // 不走成功路径
    }

    // MARK: - 放弃提示（simcodex R1 下沉：原为 PullImageSheet 的 @State，活不过 sheet 重建）

    /// 「后台可能仍在下载」这份事实必须活过 sheet 的关闭与重建——sheet 的 `@State`
    /// 做不到（`.sheet` 关闭即拆内容层级），所以它属于常驻 store 的一格。
    @Test("cancel 记下被放弃的 ref；收尾落 idle 后仍在；下一次 pull 起手清空")
    func abandonedReferenceSurvivesUIRebuild() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullStreamSuspends(true)
        await fake.setPullProgress([progress(1, 2)])
        let store = ImagePullStore(client: fake) {}
        let r = ref("a:1")

        #expect(store.lastAbandonedReference == nil)

        store.pull(r)
        await fake.awaitPullStreamReadyForTests()
        store.cancel()
        #expect(store.lastAbandonedReference == r)   // 取消即记录（不等收尾）

        await fake.finishPullStream()
        await store.awaitCurrentTaskForTests()
        #expect(store.state == .idle)
        #expect(store.lastAbandonedReference == r)   // 落 idle 后提示仍在——sheet 重建也读得到

        await fake.setPullStreamSuspends(false)
        store.pull(ref("b:2"))                       // 下一次 pull 起手清空
        #expect(store.lastAbandonedReference == nil)
        await store.awaitCurrentTaskForTests()
    }

    // MARK: - dismiss

    @Test("dismiss：failed/done → idle")
    func dismissResets() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.inject(.runtimeUnavailable, for: .pullImage)
        let store = ImagePullStore(client: fake) {}

        store.pull(ref())
        await store.awaitCurrentTaskForTests()
        #expect({ if case .failed = store.state { return true } else { return false } }())

        store.dismiss()
        #expect(store.state == .idle)
    }

    // MARK: - T9.0 pull probe 装置自证（codex #4）

    @Test("T9.0 装置：挂起 pull 流可被主动 yield + finish 驱动到完成")
    func pullProbeDriveToFinish() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        await fake.setPullStreamSuspends(true)
        await fake.setPullProgress([progress(1, 2)])
        let store = ImagePullStore(client: fake) {}
        let r = ref()

        store.pull(r)
        await fake.awaitPullStreamReadyForTests()      // ★ 等建流，避免 ready 前操作冻死（本仓挂起流坑）
        await fake.yieldPullProgress(progress(2, 2))   // 主动投递一条
        await fake.finishPullStream()                  // 主动正常结束
        await store.awaitCurrentTaskForTests()

        #expect(store.state == .done(reference: r))     // 装置驱动的流被 store 消费到终态
    }
}
