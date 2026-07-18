import Foundation
import Observation

/// 日志窗口的 UI 编排。**只做编排，不做判断**——脱敏（`LogRedactor`）、有界缓冲
/// （`LogRingBuffer`）、drain（`LogTailer`）、搜索（`LogFilter`）全部住核心层，
/// 这里只负责「什么时候起一条 follow 会话、什么时候读快照、什么时候拆」。
///
/// ## 它为什么住在 `ContainerCore` 而不是 app target
///
/// 跟 `ContainerListStore` 同一条纪律：它不 import SwiftUI，是一台纯状态机
/// （输入是 `ContainerRuntimeClient` + `ContainerListStore` + 一个「现在是哪一代」的闭包，
/// 输出是 `Phase`/`lines`）。app target 没有测试 target，放在那儿就一行测试都跑不了。
///
/// ## 暂停是 view 层概念（D-C'）
///
/// `LogTailer` 没有「停止消费」这条路——它永远 drain，多余的行进有界 ring、丢最旧。
/// 这里的「暂停」只冻结两件事：自动滚动（view 层）与快照刷新（`isPaused` 挡住轮询写回
/// `lines`）。`LogTailer` 底下照样在收行，暂停期间攒的内容，恢复时一次性看得到。
///
/// ## redaction context 的来源（D-B'）
///
/// 从 `ContainerListStore.displayedContainers` 里按 id 现查——这份列表是 app 已经在维护的
/// 唯一真源。查不到（列表还没加载完，或这个 ID 已经从列表消失）→ `.unresolved` →
/// **fail closed**：不建立 follow。这是同步查找，不额外发一次 XPC。
///
/// ## L1'：订阅 supervisor 换代
///
/// follow 会话开始时记下当时的 `RuntimeGeneration`；快照轮询每一轮都比一次
/// 「现在是哪一代」。变了 → 说明中途死过一次（`FileHandle` 可能指向一个已经 unlink 的
/// 日志文件——`seekToEnd()` 对着死 fd 照样成功，不会报错，P1-5）。这里选择**显式拆流 +
/// 横幅**，不是静默重开：换代之后旧 fd 是否还有意义、该不该自动续上，是用户该看见并决定的事，
/// 不是这个 App 该替他悄悄猜的事。
@MainActor
@Observable
public final class LogWindowStore {

    public enum Phase: Equatable {
        /// 还没决定用哪份 redaction context——查 `ContainerListStore` 是同步的，
        /// 这个态理论上只存在一瞬间，但仍然是一个真实的中间态，不能跳过。
        case resolvingRedaction

        /// `RedactionContext` 解析不出来（列表未加载 / 该 ID 不在列表里）。**没有建立 follow。**
        case unresolvedRedaction

        case following

        /// 上游流自己结束了（正常关闭或报错）。`reason` 为 `nil` 表示正常结束。
        case streamEnded(reason: String?)

        /// 换代之后主动拆掉的 follow（L1'）。**不是「流报错了」**——旧连接可能还在应答，
        /// 只是它已经不代表「当前这一代」了，所以不能再当成「正在跟随」呈现给用户。
        case generationStale
    }

    public private(set) var phase: Phase = .resolvingRedaction
    public private(set) var lines: [RedactedLogLine] = []

    public var searchQuery: String = ""
    public var isPaused = false

    public var filteredLines: [RedactedLogLine] {
        let options = searchQuery.isEmpty ? nil : LogFilter.Options(query: searchQuery)
        return LogFilter.apply(options, to: lines)
    }

    private let id: ContainerID
    private let client: any ContainerRuntimeClient
    private let containers: ContainerListStore
    private let currentGeneration: () -> RuntimeGeneration?

    private var tailer: LogTailer?

    /// 外层的 follow 会话 Task（A2：跟 `StatsWindowStore.pollTask` 一致）。持有它才能让
    /// `pollLoop` 里的 `while !Task.isCancelled` 真正生效——此前这里从不 cancel 任何 Task，
    /// 那条判据是死代码，唯一起作用的闸只有 `sessionToken`。`cancel()` 只会让这个 Task
    /// （store 的轮询）提前收工，不影响 `LogTailer` 的 drain（那是 `detachCurrentTailer()`
    /// 的职责，两者刻意分开——D-C' 要求 tailer 永远 drain，跟「UI 还看不看」无关）。
    private var pollTask: Task<Void, Never>?

    /// 单飞令牌（`ContainerListStore.refresh()` 同一条纪律）：`open()` 可能被用户连点
    /// 「重试」触发好几次，跨 `await` 之后必须先证明自己还是最新那一次会话，才准写回状态。
    private var sessionToken = 0

    public init(
        id: ContainerID,
        client: any ContainerRuntimeClient,
        containers: ContainerListStore,
        currentGeneration: @escaping () -> RuntimeGeneration?
    ) {
        self.id = id
        self.client = client
        self.containers = containers
        self.currentGeneration = currentGeneration
    }

    /// 窗口出现时调一次；「重试」/「重新打开」按钮也调它——都是「从头起一条会话」。
    ///
    /// **不是 `async`**：这里只是同步地宣布「新会话开始」（令牌 +1、状态复位、旧 tailer
    /// 甩给一个不等结果的清理 Task），跟随本身是一条不打算被等待完成的长驻循环。
    /// 调用方（view 的 `.task` / 按钮）不需要 `Task { await ... }`，直接调。
    public func open() {
        sessionToken += 1
        let token = sessionToken

        pollTask?.cancel()
        detachCurrentTailer()
        phase = .resolvingRedaction
        lines = []

        let redaction = resolveRedaction()

        guard case .resolved = redaction else {
            phase = .unresolvedRedaction
            return
        }

        let startedGeneration = currentGeneration()

        pollTask = Task {
            do {
                let rawStream = try await client.followLogs(id: id)
                guard token == sessionToken else { return }

                let tailer = LogTailer(rawStream: rawStream, redaction: redaction)
                self.tailer = tailer
                phase = .following

                await pollLoop(tailer: tailer, token: token, startedGeneration: startedGeneration)
            } catch {
                guard token == sessionToken else { return }
                phase = .streamEnded(reason: String(describing: error))
            }
        }
    }

    /// 窗口关闭时调。**不清空已有内容**——`LogTailer.cancel()` 本身就不清 ring buffer，
    /// 这里跟它保持一致：关窗不等于用户想丢掉刚跟到的日志。
    public func close() {
        sessionToken += 1
        pollTask?.cancel()
        pollTask = nil
        detachCurrentTailer()
    }

    public func clear() {
        guard let tailer else { return }
        Task {
            await tailer.clear()
            lines = []
        }
    }

    // MARK: -

    /// 从当前 `Container` 快照的 env 取已知密钥集合。同步查找，不发 XPC。
    private func resolveRedaction() -> RedactionContext {
        guard let container = containers.displayedContainers.first(where: { $0.id == id }) else {
            return .unresolved
        }
        return .resolved(secrets: container.environment.map(\.value))
    }

    /// 甩掉当前 tailer：取出、置 nil、把 cancel 甩给一个不等结果的清理 Task。
    /// `open()`/`close()` 都要做这件事（A2）——提出来避免两处各写一份同样的三行。
    private func detachCurrentTailer() {
        let previousTailer = tailer
        tailer = nil
        // `cancel()` 是 actor-isolated 方法，从这个同步函数里够不到 `await`——
        // 甩给一个不关心结果的清理 Task。旧会话的令牌已经失效，它写不回任何状态。
        Task { await previousTailer?.cancel() }
    }

    /// 快照轮询：每 250ms 读一次 ring buffer 快照（節流，避免每行都触发 SwiftUI diff），
    /// 顺带做两件事——① 暂停时不写回 `lines`；② 每一轮比一次 generation（L1'）。
    private func pollLoop(tailer: LogTailer, token: Int, startedGeneration: RuntimeGeneration?) async {
        while !Task.isCancelled {
            guard token == sessionToken else { return }

            if currentGeneration() != startedGeneration {
                await tailer.cancel()
                phase = .generationStale
                return
            }

            let snapshot = await tailer.snapshot()
            let status = await tailer.status

            guard token == sessionToken else { return }

            // C2：内容没变就别写回——`@Observable` 的失效通知不看「新值等不等于旧值」，
            // 写一次就触发一次下游重算（view 的 `filteredLines`，O(n) 的 Unicode 子串搜索）。
            // `RedactedLogLine.id` 单调递增（`LogRingBuffer` 的文档），拿它比最后一条 +
            // 数量就足够判断「有没有新行进来」，不需要整份数组的 `Equatable` 比较。
            if !isPaused, hasChanged(from: lines, to: snapshot) {
                lines = snapshot
            }

            if case .streamEnded(let reason) = status {
                phase = .streamEnded(reason: reason)
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func hasChanged(from current: [RedactedLogLine], to snapshot: [RedactedLogLine]) -> Bool {
        current.count != snapshot.count || current.last?.id != snapshot.last?.id
    }
}
