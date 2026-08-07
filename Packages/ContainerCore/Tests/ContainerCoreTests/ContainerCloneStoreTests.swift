import Testing

@testable import ContainerCore

/// T9.3：`ContainerCloneStore` 加载 + 提交态机。
/// 覆盖 submit 各路径、单飞门（succeeded 后拒 + reset 再建）、envOverride 传递（用 Fake 的
/// `createCloneEnvOverrides` 观测）、以及脱敏（loadState 描述不含明文——codex #6）。
/// 可精确控制 `cloneTemplate()` 返回时机的替身（同 `GatedCreationClient` 范式）——
/// 用来确定性地制造「两次 load 交错」，而不是靠 `Task.yield()` 撞时机。
/// 第 n 次 `cloneTemplate` 返回 image 为 `img-n` 的模板，便于分辨哪一次的结果落了地。
private actor GatedCloneClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {

    private var pending: [CheckedContinuation<Int, Never>] = []

    var pendingCount: Int { pending.count }

    func cloneTemplate(for source: ContainerID) async throws(RuntimeError) -> ContainerCloneTemplate {
        let index = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            pending.append(c)
        }
        guard index >= 0 else { throw .runtimeUnavailable }   // 负数 = 被 failLoad 放行
        return ContainerCloneTemplate(
            image: ImageRef("img-\(index)")!,
            environment: [],
            mountSummary: MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0)
        )
    }

    /// 放行第 `index` 次发起的 `cloneTemplate()`（0 起），让它成功返回。
    func completeLoad(_ index: Int) {
        pending[index].resume(returning: index)
    }

    /// 放行第 `index` 次发起的 `cloneTemplate()`，让它**抛 `.runtimeUnavailable`**。
    func failLoad(_ index: Int) {
        pending[index].resume(returning: -1)
    }

    func list() throws(RuntimeError) -> [Container] { [] }
    func start(id: ContainerID) throws(RuntimeError) {}
    func stop(id: ContainerID) throws(RuntimeError) {}

    func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample {
        ContainerStatsSample()
    }
}

@MainActor
@Suite("ContainerCloneStore 加载与提交")
struct ContainerCloneStoreTests {

    private static let secretValue = "sk-clone-secret-000"

    private func sourceContainer(id: String = "src-web") -> Container {
        Container(
            id: ContainerID(id)!,
            image: ImageRef("nginx:latest")!,
            state: .stopped,
            environment: [EnvironmentVariable(key: "TOKEN", value: SecretString(Self.secretValue))]
        )
    }

    private func store(
        source: String = "src-web",
        fake: FakeContainerRuntimeClient
    ) -> ContainerCloneStore {
        ContainerCloneStore(source: ContainerID(source)!, client: fake)
    }

    // MARK: - loadTemplate

    @Test("loadTemplate 成功 → loaded（含继承 image + env）")
    func loadSucceeds() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)

        await s.loadTemplate()

        guard case .loaded(let template) = s.loadState else {
            Issue.record("expected loaded, got \(s.loadState)")
            return
        }
        #expect(template.image.rawValue == "nginx:latest")
        #expect(template.environment.count == 1)
    }

    @Test("loadTemplate 源不存在 → failed(.containerNotFound)")
    func loadSourceMissing() async {
        let fake = FakeContainerRuntimeClient(containers: [])
        let s = store(fake: fake)

        await s.loadTemplate()

        #expect(s.loadState == .failed(.containerNotFound(ContainerID("src-web")!)))
    }

    // MARK: - submit 各路径

    @Test("空 / 非法新名 → failed(.invalidName)")
    func submitInvalidName() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)
        s.newName = ""

        await s.submit()

        #expect(s.phase == .failed(.invalidName(.empty)))
    }

    @Test("新名 == 源 → failed(.nameEqualsSource)")
    func submitNameEqualsSource() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)
        s.newName = "src-web"   // == source.rawValue

        await s.submit()

        #expect(s.phase == .failed(.nameEqualsSource))
    }

    @Test("新名已存在（list 命中）→ failed(.nameAlreadyExists)，不调 createClone")
    func submitNameAlreadyExists() async {
        let existing = Container(id: ContainerID("taken")!, image: ImageRef("x")!, state: .running, environment: [])
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer(), existing])
        let s = store(fake: fake)
        s.newName = "taken"

        await s.submit()

        #expect(s.phase == .failed(.nameAlreadyExists(ContainerID("taken")!)))
        let overrides = await fake.createCloneEnvOverrides
        #expect(overrides.isEmpty)   // 没调 createClone
    }

    @Test("list 前置失败 → failed(.precheckFailed)，不盲建")
    func submitPrecheckFails() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        await fake.inject(.runtimeUnavailable, for: .list)
        let s = store(fake: fake)
        s.newName = "cloned"

        await s.submit()

        #expect(s.phase == .failed(.precheckFailed(.runtimeUnavailable)))
        let overrides = await fake.createCloneEnvOverrides
        #expect(overrides.isEmpty)
    }

    @Test("createClone 失败 → failed(.createFailed)")
    func submitCreateFails() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        await fake.inject(.runtimeUnavailable, for: .createClone)
        let s = store(fake: fake)
        s.newName = "cloned"

        await s.submit()

        #expect(s.phase == .failed(.createFailed(.runtimeUnavailable)))
    }

    @Test("提交成功 → succeeded")
    func submitSucceeds() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)
        s.newName = "cloned"

        await s.submit()

        #expect(s.phase == .succeeded(ContainerID("cloned")!))
    }

    // MARK: - 单飞门（codex #7）

    @Test("succeeded 后再 submit 被拒；reset 后可再建")
    func rejectAfterSucceededThenReset() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)
        s.newName = "cloned"
        await s.submit()
        #expect(s.phase == .succeeded(ContainerID("cloned")!))

        let accepted = await s.submit()   // succeeded 期间拒
        #expect(accepted == false)

        s.reset()
        #expect(s.phase == .editing)
        s.newName = "cloned2"
        let acceptedAfterReset = await s.submit()
        #expect(acceptedAfterReset == true)
        #expect(s.phase == .succeeded(ContainerID("cloned2")!))
    }

    // MARK: - envOverride 传递（用 Fake 观测，codex #6）

    @Test("envOverride == nil（未编辑）→ createClone 收到 nil（原样克隆）")
    func envOverrideNil() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)
        s.newName = "cloned"

        await s.submit()

        let overrides = await fake.createCloneEnvOverrides
        #expect(overrides.count == 1)
        #expect(overrides[0] == nil)   // 原样克隆：env 不进 UI/不 override
    }

    @Test("envOverride != nil（编辑过）→ createClone 收到该 env")
    func envOverrideSet() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)
        s.newName = "cloned"
        let edited = [EnvironmentVariable(key: "TOKEN", value: SecretString("edited-value"))]
        s.setEnvironmentOverride(edited)

        await s.submit()

        let overrides = await fake.createCloneEnvOverrides
        #expect(overrides.count == 1)
        #expect(overrides[0] == edited)
    }

    // MARK: - 脱敏（codex #6）

    @Test("loadState 描述不含明文 secret（env 全程 SecretString）")
    func loadStateRedacted() async {
        let fake = FakeContainerRuntimeClient(containers: [sourceContainer()])
        let s = store(fake: fake)

        await s.loadTemplate()

        #expect(!String(describing: s.loadState).contains(Self.secretValue))
    }

    // MARK: - T9.4b：load 令牌（★ `@MainActor` 在 await 处可重入，本仓栽过三次）

    /// T9.7 的「加载失败重试」按钮就是第二次 `loadTemplate()`——两次 load 必然可以交错，
    /// 而**返回顺序不由发起顺序决定**。没有令牌时，先发起后返回的旧 load 会覆盖新 load 的结果。
    ///
    /// 断言的是**不变式本身**（`loadState` 停在新一次的结果上），不是下游时序
    /// （坑清单「断言副作用 = 跟调度器赛跑，必然假绿」）。
    private func waitForPending(_ count: Int, on client: GatedCloneClient) async {
        for _ in 0..<10_000 {
            if await client.pendingCount >= count { return }
            await Task.yield()
        }
        Issue.record("等不到 \(count) 个在途 cloneTemplate()——store 可能压根没发起加载")
    }

    @Test("重入：旧 load 后返回，不得覆盖新 load 的结果")
    func staleLoadDoesNotOverwrite() async {
        let client = GatedCloneClient()
        let s = ContainerCloneStore(source: ContainerID("src-web")!, client: client)

        let first = Task { await s.loadTemplate() }
        await waitForPending(1, on: client)
        let second = Task { await s.loadTemplate() }   // 重试按钮：第二次 load
        await waitForPending(2, on: client)

        // 新的（第 1 次索引）先返回并落地。
        await client.completeLoad(1)
        await second.value
        #expect(s.loadState == .loaded(
            ContainerCloneTemplate(
                image: ImageRef("img-1")!,
                environment: [],
                mountSummary: MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0)
            )
        ))

        // 旧的（第 0 次）后返回 —— 必须被令牌拦住，loadState 不变。
        await client.completeLoad(0)
        await first.value
        #expect(s.loadState == .loaded(
            ContainerCloneTemplate(
                image: ImageRef("img-1")!,
                environment: [],
                mountSummary: MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0)
            )
        ))
    }

    /// **失败回写也必须过令牌**——否则「旧 load 失败」会把新 load 的成功态打成 failed，
    /// 用户看到的是「加载失败」而模板其实已经加载好了。`catch` 分支漏加令牌是极易发生的半修。
    @Test("重入：旧 load 的失败回写同样不得覆盖新 load 的成功")
    func staleLoadFailureDoesNotOverwrite() async {
        let client = GatedCloneClient()
        let s = ContainerCloneStore(source: ContainerID("src-web")!, client: client)

        let first = Task { await s.loadTemplate() }
        await waitForPending(1, on: client)
        let second = Task { await s.loadTemplate() }
        await waitForPending(2, on: client)

        await client.completeLoad(1)      // 新的成功并落地
        await second.value
        guard case .loaded = s.loadState else {
            Issue.record("前置：期望 loaded，实得 \(s.loadState)")
            return
        }

        await client.failLoad(0)          // 旧的失败后返回 —— 必须被拦
        await first.value

        guard case .loaded = s.loadState else {
            Issue.record("陈旧失败回写击穿了令牌：loadState 变成 \(s.loadState)")
            return
        }
    }
}
