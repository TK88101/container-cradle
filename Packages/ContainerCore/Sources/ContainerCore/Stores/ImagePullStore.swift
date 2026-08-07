import Observation

/// App 内 pull 一个公开镜像的 UI 态机（Day 16 T9.2，能力 C 档 A）。**纯逻辑住 core、可测**。
///
/// ## 所有权模型（codex #1）
///
/// `pull(_:)` 是**同步**方法——内部起 `task = Task { … }` 消费流后立即返回，store 独占该 task 句柄。
/// **不做 async pull**（async + 持 `task?.cancel()` 是两套模型，测试易只等到「发起」非终态）。
/// 测试用 `awaitCurrentTaskForTests()` 等消费 Task 到终态。
///
/// ## 重入令牌（codex #2，★本仓 Day5 epoch 同款：`await` 就是窗口，本仓栽过三次）
///
/// 单调 `pullGeneration`（每次 `pull` / `cancel` 使它前进）。消费 Task 捕获自己那一代 `gen`。
/// **所有异步回写**（progress / done / failed / 取消收尾落 idle）经 `applyIfCurrent(gen)`——旧代 Task
/// 在 cancel 后即使继续收到 yield/finish/error，一律被令牌拦下写不进 `state`。取消 / 新 pull 令
/// `pullGeneration` 前进 = 旧代彻底失效。
@MainActor
@Observable
public final class ImagePullStore {

    /// pull 生命周期。非法组合用 enum 表达不出来。
    public enum State: Sendable, Equatable {
        case idle
        case pulling(reference: ImageRef, progress: PullProgress?)  // progress nil = 建流成功但首事件未到
        case cancellingForeground(reference: ImageRef)              // 已请求取消，前台放弃、等旧 task 收尾
        case failed(reference: ImageRef, kind: FailureKind)
        case done(reference: ImageRef)
    }

    /// 双错误通道忠实建模：建流阶段 typed `RuntimeError`；流内 `any Error`（Swift 无 typed-throws async 序列，
    /// 同 `followLogs`）。流内错误转 `String`（`localizedDescription`）以保 `State` 的 `Equatable`。
    public enum FailureKind: Sendable, Equatable {
        case setup(RuntimeError)
        case stream(String)
    }

    public private(set) var state: State = .idle

    /// 用户最近一次「前台放弃」的 ref（simcodex R1，自 `PullImageSheet` 的 `@State` 下沉）。
    /// UI 用它在收尾落回 `.idle` 后仍钉住「后台可能仍在下载」的提示——这份事实必须
    /// 活过 sheet 的关闭与重建（sheet 的 `@State` 活不过），所以住常驻 store。
    /// `cancel()` 置位、下一次 `pull()` 起手清空；`dismiss()` 不清（它只复位终态）。
    public private(set) var lastAbandonedReference: ImageRef?

    private let client: any ContainerRuntimeClient

    /// pull 终态（done / 取消放弃）后刷新 `ImageListStore` 用——注入回调而非直接依赖它（同 `ContainerActionStore`）。
    private let onCompleted: @MainActor () async -> Void

    private var task: Task<Void, Never>?
    private var pullGeneration = 0

    public init(
        client: any ContainerRuntimeClient,
        onCompleted: @escaping @MainActor () async -> Void
    ) {
        self.client = client
        self.onCompleted = onCompleted
    }

    /// 发起 pull。**单飞门（codex #11）**：仅 `.pulling` / `.cancellingForeground` 拒；
    /// `.idle` / `.failed` / `.done` 允许直接发起（新 pull 覆盖旧终态，不必先 `dismiss()`）。
    public func pull(_ reference: ImageRef) {
        switch state {
        case .pulling, .cancellingForeground:
            return   // busy：拒（单飞门；`await` 之前完成的同步判断，是防线）
        case .idle, .failed, .done:
            break
        }

        pullGeneration += 1
        let gen = pullGeneration
        lastAbandonedReference = nil   // 新一次 pull 起手：上一次的放弃提示到此为止
        state = .pulling(reference: reference, progress: nil)
        task = Task { [weak self] in
            await self?.runPull(reference, gen: gen)
        }
    }

    /// 前台放弃（codex #2/#3）。**同步原子段、无 await**（本仓「guard 写在 await 外没用」纪律）：
    /// `pullGeneration += 1` 令旧代 `runPull` 的后续回写全部被 `applyIfCurrent` 拦；置 `.cancellingForeground`
    /// （可观测）；起收尾 task 等旧 task 真正结束后落 `.idle`。**不调 `onCompleted`**——前台放弃即放弃，
    /// 列表刷新留给下次窗口打开的 `.task refresh`（收窄登记：实施期决策，避免 fire-and-forget 刷新的测试不确定性）。
    public func cancel() {
        guard case .pulling(let reference, _) = state else { return }

        lastAbandonedReference = reference
        pullGeneration += 1
        let finalizeGen = pullGeneration
        state = .cancellingForeground(reference: reference)

        let cancelled = task
        cancelled?.cancel()
        task = Task { [weak self] in
            await cancelled?.value            // 等旧 runPull 真正收尾（流 onTermination 结束迭代）
            await self?.finalizeCancel(gen: finalizeGen)
        }
    }

    /// 从终态复位到 idle（`.failed` / `.done` → `.idle`）。pulling / cancelling 期间是 no-op。
    public func dismiss() {
        switch state {
        case .failed, .done:
            state = .idle
        case .idle, .pulling, .cancellingForeground:
            break
        }
    }

    /// 测试等消费 Task（或取消收尾 task）到终态——断言不变式前用，避免跟调度器赛跑。
    func awaitCurrentTaskForTests() async {
        await task?.value
    }

    // MARK: - 私有

    private func runPull(_ reference: ImageRef, gen: Int) async {
        let stream: AsyncThrowingStream<PullProgress, any Error>
        do {
            stream = try await client.pullImage(reference)
        } catch {
            applyIfCurrent(gen) { self.state = .failed(reference: reference, kind: .setup(error)) }
            return
        }

        do {
            for try await progress in stream {
                applyIfCurrent(gen) { self.state = .pulling(reference: reference, progress: progress) }
            }
        } catch {
            applyIfCurrent(gen) {
                self.state = .failed(reference: reference, kind: .stream(error.localizedDescription))
            }
            return
        }

        // 流正常结束（或被取消而结束）。仅当仍是本代才落 done + 刷新——取消后本代已失效，被令牌拦，
        // 既不误报 done，也不调成功 onCompleted（codex #3「取消后不走成功路径」）。
        if applyIfCurrent(gen, { self.state = .done(reference: reference) }) {
            await onCompleted()   // gate 返回 true 与 onCompleted 之间无 await → 代不会漂移
        }
    }

    /// 令牌闸：仅当 `gen` 仍是当前代才执行回写并返回 true；旧代（被 cancel / 新 pull 取代）返回 false。
    @discardableResult
    private func applyIfCurrent(_ gen: Int, _ body: () -> Void) -> Bool {
        guard gen == pullGeneration else { return false }
        body()
        return true
    }

    /// 取消收尾：旧 task 结束后落 idle——仅当期间没有新 pull 抢占（`finalizeGen` 仍当前）。
    private func finalizeCancel(gen: Int) {
        guard gen == pullGeneration else { return }
        state = .idle
    }
}
