import Foundation
import Observation

/// stats 窗口的 UI 编排。差分数学（`CPUPercentCalculator`）、首样本占位、sparkline
/// 有界化全部住 `StatsCollector`（core actor）——这里只负责「窗口开着就 1s poll 一次，
/// 关了就停」，以及 P1-9 那道「回写前重新证明自己还是最新会话」的闸。
///
/// ## 它为什么住在 `ContainerCore` 而不是 app target
///
/// 跟 `LogWindowStore`/`ContainerListStore` 同一条纪律：纯状态机，不 import SwiftUI，
/// app target 没有测试 target，放在那儿就零测试覆盖。
///
/// ## P1-9：poll 结果回写前必须重新校验令牌
///
/// `StatsCollector.poll()` 内部已经有自己的 epoch（防的是它自己被并发 `poll()`/`reset()`
/// 打断）。但那道闸只保证 **collector 内部** `latest` 不被迟到结果污染，挡不住**这一层**
/// 的窗口——`await collector.poll()` 与 `await collector.latest` 都是 await 点，
/// 若窗口在这中间关闭又重开（新的 `StatsWindowStore.start()` 调用），旧的 poll 循环
/// 还在跑，读到的 `latest` 会被写进**已经不该再更新**的 `snapshot`。
/// `sessionToken` 就是这道闸：跨过两次 await 之后，只有 token 仍然吻合才落地。
@MainActor
@Observable
public final class StatsWindowStore {

    public private(set) var snapshot: ContainerStatsSnapshot?

    private let id: ContainerID
    private let client: any ContainerRuntimeClient

    private var pollTask: Task<Void, Never>?
    private var sessionToken = 0

    public init(id: ContainerID, client: any ContainerRuntimeClient) {
        self.id = id
        self.client = client
    }

    /// 窗口出现时调一次。**同步**，跟 `LogWindowStore.open()` 一样：起一条不等待完成的
    /// 长驻轮询，调用方直接调，不用 `Task { await ... }`。
    public func start() {
        pollTask?.cancel()
        sessionToken += 1
        let token = sessionToken
        snapshot = nil

        let collector = StatsCollector(client: client, id: id)

        pollTask = Task {
            while !Task.isCancelled {
                await collector.poll()
                let latest = await collector.latest

                // 两次 await 都跨过去之后才检查——中间任何一刻若窗口已经重开，
                // token 会先变、这里的写回会被整体丢弃（P1-9）。
                guard token == sessionToken, !Task.isCancelled else { return }
                snapshot = latest

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 窗口关闭时调。**先失效令牌，再取消 Task**——顺序不是随便的：`cancel()` 只能防住
    /// 「还没开始的下一轮 `await`」，防不住「已经在 await 中途」的那一轮；令牌才是那道闸。
    public func stop() {
        sessionToken += 1
        pollTask?.cancel()
        pollTask = nil
    }
}
