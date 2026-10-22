import Foundation
import Observation

/// 「新建容器」表单的提交状态机（Day 16 能力 A）。**纯逻辑住 core、可测**——
/// 拒绝制、建后启、启动失败保留态都是判断逻辑，放 view 里等于零测试（坑清单「可测性不是洁癖」）。
/// view 只拿 `phase` 和 `submit(_:)`，保持愚蠢。
///
/// ## 提交序列（四路径）
///
/// `list()` 存在性检查 → 命中即拒（不调 create）→ 否则 `create` →（`startAfterCreate` 时）`start`。
/// - **名字唯一性靠存在性、不嗅错误码**（R14）：`list()` 里出现同名 = 拒；不去解析 create 的错误文本。
/// - **建后启是两步**：`create` 落一个 stopped 容器，`start` 再拉起。返回的 `ContainerID` 是
///   持久化 identity（codex #7），不靠对名字做字符串手术。
/// - **`startAfterCreate: false` 时只建不启**（UI 的「创建」按钮）：`start` 不发生，
///   `.startFailed` 在这条路径上**结构上不可能出现**——这是无默认值的理由（B 段 codex #1）。
/// - **启动失败不回滚**：`create` 成功但 `start` 抛 → 容器**保留**（stopped），**绝不调 `delete`**。
///   自动删掉用户刚建好的容器，比「建好了但没自动启动、你自己点一下」糟糕得多——
///   同 `ContainerActionStore.restart` 的「已停止但启动失败」半失败纪律。
///
/// ## 单飞：拒绝制
///
/// 已有提交在途时，新 `submit` **直接拒**（返回 `false`）——一个创建表单一次只该提交一次
/// （用户双击提交按钮是真实风险）。令牌是 `phase.isBusy`（Day 25 起含 `.confirming`）：**检查 + 置位是同一段同步代码**，
/// 中间没有 `await`——`@MainActor` 在 `await` 处可重入（★坑清单，本仓栽过三次），
/// 按钮 disabled 只是体验，这里才是防线。
///
/// ## 超时后的确认段（Day 25，Plan 2026-10-22 §2.1）
///
/// create 抛 `.outcomeUnknown(pending: operationID)` ⇒ `.confirming`，凭 operationID 取回**那一次**的真实结果：
/// 成功才算成功，「创建并启动」才补上 `start`（G-D）；确定失败照实报；仍没结果则放弃取回、回到今天的文案。
/// 同名后来者在 runtime 就被 `.creationInProgress` 挡下，拿不到别人的结果——自动 `start` 因此不越权。
/// 单飞令牌是 `phase.isBusy`（`.submitting` 与 `.confirming` 都拒），不是 `== .submitting`（codex R1-P2）。
@MainActor
@Observable
public final class ContainerCreationStore {

    /// 提交生命周期。非法组合（如「submitting 同时 succeeded」）用 enum 表达不出来。
    public enum Phase: Sendable, Equatable {
        case idle
        case submitting
        /// create 超时，正在取回那一次的真实结果（Day 25）。
        case confirming
        case succeeded(ContainerID)
        case failed(Failure)

        /// 提交在途（含确认中）。单飞门、按钮 disabled、进行中提示都看它。
        public var isBusy: Bool {
            switch self {
            case .submitting, .confirming: true
            case .idle, .succeeded, .failed: false
            }
        }
    }

    /// 提交失败的形态。**四类分开**——对用户是完全不同的处境，UI 文案与后续动作都不同。
    public enum Failure: Sendable, Equatable {
        /// 前置 `list()` 已发现同名容器 → 没有调用 `create`。
        case nameAlreadyExists(ContainerID)
        /// 前置 `list()` 自己失败（如运行时不在）→ 存在性未知，**不盲建**，没有调用 `create`。
        case precheckFailed(RuntimeError)
        /// `create` 抛错 → 没有调用 `start`。
        case createFailed(RuntimeError)
        /// `create` 成功但 `start` 抛错 → 容器**已建、保留（stopped）**，未回滚删除。
        case startFailed(ContainerID, RuntimeError)
    }

    public private(set) var phase: Phase = .idle

    /// 本次提交的开始时刻。不变式：`phase.isBusy ⇔ submittedAt != nil`（Day 25：「仍在进行」提示的时间事实）。
    public private(set) var submittedAt: Date?

    private let client: any ContainerRuntimeClient
    /// **同步**时间源：要和单飞门的「检查 + 置位」在同一段无 `await` 的代码里取（codex R2-P1）。
    private let now: () -> Date

    public init(client: any ContainerRuntimeClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    /// 提交一份创建意图。
    ///
    /// 返回 `false` **仅**表示被单飞拒（已有提交在途）；`true` 表示本次被受理并跑到了终态
    /// （成功或失败，读 `phase` 区分）。
    ///
    /// `startAfterCreate` **刻意不给默认值**（Day 16 B 段 codex #1）：UI 上「创建」与
    /// 「创建并启动」是两个按钮，而这两条路径的失败形态**结构上不同**——`false` 时
    /// `.startFailed` 不可能出现。给默认值会让调用点读不出自己走的是哪条，
    /// 而这恰恰是用户点了哪个按钮的唯一记录。
    @discardableResult
    public func submit(_ spec: ContainerCreationSpec, startAfterCreate: Bool) async -> Bool {
        // 单飞：检查 + 置位的同步原子段，`await` 之前完成——这是拒绝制的全部防线。
        guard !phase.isBusy else { return false }
        phase = .submitting
        submittedAt = now()

        // 前置存在性检查：do/catch 各自独立（typed throws 在单调用的 catch 里才是 RuntimeError，
        // 多调用同块会退化成 any Error——ContainerListStore.load 记过的坑）。
        let existing: [Container]
        do {
            existing = try await client.list()
        } catch {
            settle(.failed(.precheckFailed(error)))
            return true
        }

        if let clash = existing.first(where: { $0.id.rawValue == spec.name.value }) {
            settle(.failed(.nameAlreadyExists(clash.id))) // 命中即拒，不调 create
            return true
        }

        let createdID: ContainerID
        do {
            createdID = try await client.create(spec)
        } catch {
            guard case .outcomeUnknown(_, let operationID?) = error else {
                settle(.failed(.createFailed(error))) // 未调 start
                return true
            }
            // 超时：凭 operationID 取回那一次的真实结果（Day 25）。
            phase = .confirming
            switch await PendingCreationConfirmation.confirm(operationID, client: client) {
            case .success(let id):
                createdID = id
            case .failure(let confirmError):
                settle(.failed(.createFailed(confirmError)))
                return true
            }
        }

        // 「只建不启」：`start` 根本不发生 → `.startFailed` 在这条路径上结构性地不可能出现。
        if startAfterCreate {
            do {
                try await client.start(id: createdID)
            } catch {
                // 保留态：容器已建，不回滚删除。
                settle(.failed(.startFailed(createdID, error)))
                return true
            }
        }

        settle(.succeeded(createdID))
        return true
    }

    /// 进终态，同时清掉 `submittedAt`（守不变式 `isBusy ⇔ submittedAt != nil`）。
    private func settle(_ terminal: Phase) {
        phase = terminal
        submittedAt = nil
    }

    /// 回到 `.idle`，让同一个常驻 store 能承接下一次提交。
    ///
    /// 必要性不是洁癖：本 store 常驻 `AppModel`（单实例创建窗口关了再开草稿不该蒸发），
    /// 不重置的话第二次开窗看到的是上一次的 `.succeeded` / `.failed` —— 一个已经完成的
    /// 提交结果冒充当前状态。
    public func reset() {
        settle(.idle)
    }
}
