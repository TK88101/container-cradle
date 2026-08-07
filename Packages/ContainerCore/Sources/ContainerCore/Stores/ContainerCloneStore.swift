import Observation

/// 「以此为模板新建」（clone）的加载 + 提交态机（Day 16 T9.3，能力 B）。**纯逻辑住 core、可测**。
///
/// ## env 最小暴露 + 脱敏边界（codex #5 复审定稿）
///
/// 安全边界不是「env 不进 UI」，而是**「明文不以普通 `String` 进入长寿命 store / 描述 / 快照 / 日志」**。
/// 能力 B 明确要 clone 表单 concealed 展示 env 条目并可 reveal 编辑——故 `loadState.loaded(template)`
/// 公开只读模板 env（`SecretString`，默认打码，reveal 走 app 层已登记出口 `SecretField`）。
/// store **不预生成可变 env 草稿**；`environmentOverride == nil` = 用户未编辑 → 提交原样克隆；
/// 仅编辑后写入 override（值仍 `SecretString`）。store 层**零 `reveal()`**。
///
/// ## 单飞门（codex #7）
///
/// `submit()` 仅在 `.editing` / `.failed` 可发起（`.submitting` / `.succeeded` 拒）——succeeded 后须
/// `reset()` 才能再建，否则复用旧 `newName`/`environmentOverride` 会二次 create。令牌是 `phase`：
/// **检查 + 置 `.submitting` 是同步原子段**（`ContainerName` 校验同步、无 await），中间不可被重入插入
/// （★本仓 `@MainActor` 在 await 处可重入，栽过三次）。
@MainActor
@Observable
public final class ContainerCloneStore {

    public enum LoadState: Sendable, Equatable {
        case loading
        case loaded(ContainerCloneTemplate)   // 只读模板：image + mountSummary + env（SecretString，默认打码）
        case failed(RuntimeError)
    }

    public enum Phase: Sendable, Equatable {
        case editing
        case submitting
        case succeeded(ContainerID)
        case failed(SubmitFailure)
    }

    public enum SubmitFailure: Sendable, Equatable {
        case invalidName(ContainerNameError)
        case nameEqualsSource                       // 新名 == 源 id（clone 必须换名）
        case nameAlreadyExists(ContainerID)         // 提交前 list 命中（靠存在性不嗅错误码 R14）
        case precheckFailed(RuntimeError)           // list 自身失败 → 不盲建
        case createFailed(RuntimeError)
    }

    public let source: ContainerID
    public private(set) var loadState: LoadState = .loading
    public private(set) var phase: Phase = .editing
    public var newName: String = ""

    /// nil = 用户未编辑 → 提交原样克隆；非 nil = 用户编辑过的覆盖 env（值仍 `SecretString`）。
    public private(set) var environmentOverride: [EnvironmentVariable]?

    private let client: any ContainerRuntimeClient

    /// 单调递增的加载世代——`loadTemplate()` 的回写令牌（见该方法文档）。
    private var loadGeneration = 0

    public init(source: ContainerID, client: any ContainerRuntimeClient) {
        self.source = source
        self.client = client
    }

    /// 加载 clone 预填模板（纯 domain，app 不碰上游 configuration）。
    ///
    /// ## 世代令牌（★ `@MainActor` 在 `await` 处可重入，本仓栽过三次）
    ///
    /// 加载失败后的「重试」按钮就是**第二次** `loadTemplate()`，两次必然可以交错，
    /// 而返回顺序**不由发起顺序决定**。没有令牌时，先发起后返回的旧 load 会把新 load 的
    /// 结果覆盖掉（`.loaded` 被旧的 `.failed` 打回，用户看到「加载失败」而模板其实已经好了）。
    ///
    /// 令牌递增 + 「校验与写回焊成同一段同步代码」（`await` 之后立刻 `guard`，中间不再挂起）
    /// 是本仓的既定形状（同 `ImagePullStore.pullGeneration`）。
    /// **成功与失败两条回写都要过令牌**——只守成功那条是最常见的半修。
    public func loadTemplate() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        do {
            let template = try await client.cloneTemplate(for: source)
            guard generation == loadGeneration else { return }   // 陈旧成功：丢弃
            loadState = .loaded(template)
        } catch {
            guard generation == loadGeneration else { return }   // 陈旧失败：同样丢弃
            loadState = .failed(error)
        }
    }

    /// 写入 env 覆盖（明文已在 view 层包进 `SecretString`）。nil = 恢复「原样克隆」。
    public func setEnvironmentOverride(_ env: [EnvironmentVariable]?) {
        environmentOverride = env
    }

    /// 提交 clone。返回 `false` **仅**表示被单飞门拒（submitting/succeeded 期间）；`true` = 本次被受理并跑到终态。
    @discardableResult
    public func submit() async -> Bool {
        // 单飞门：检查 + 后续置位是同步原子段，await 之前完成——这是防线（codex #7）。
        switch phase {
        case .submitting, .succeeded:
            return false
        case .editing, .failed:
            break
        }

        let name: ContainerName
        do {
            name = try ContainerName(newName)
        } catch {
            phase = .failed(.invalidName(error))
            return true
        }

        guard name.value != source.rawValue else {
            phase = .failed(.nameEqualsSource)   // clone 必须换名
            return true
        }

        phase = .submitting   // 置位在最后一个同步校验之后、首个 await 之前 → 重入拒

        let existing: [Container]
        do {
            existing = try await client.list()
        } catch {
            phase = .failed(.precheckFailed(error))
            return true
        }

        if let clash = existing.first(where: { $0.id.rawValue == name.value }) {
            phase = .failed(.nameAlreadyExists(clash.id))   // 命中即拒，不调 create
            return true
        }

        do {
            let id = try await client.create(clonedFrom: source, name: name, envOverride: environmentOverride)
            phase = .succeeded(id)
        } catch {
            phase = .failed(.createFailed(error))
        }
        return true
    }

    /// succeeded / failed 后回到可编辑态供再建（codex #7）。保留草稿（用户可改名重提交）。
    public func reset() {
        phase = .editing
    }
}
