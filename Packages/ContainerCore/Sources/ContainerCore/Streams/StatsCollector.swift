import Foundation

/// 轮询 `ContainerRuntimeClient.stats(id:)`，持前一样本，算出 UI 直接消费的 `ContainerStatsSnapshot`。
///
/// ## ★ `poll()` 跨 `await` 之后必须重新证明自己还活在同一个世界里（P1-9，codex review 定案）
///
/// `poll()` 里有两次 `await`（读时钟、打 XPC）。这段时间里，另一次 `poll()`（stats 窗口的
/// 定时器又触发了一轮）或 `reset()`（窗口关了又开）完全可能插进来——actor 在 `await` 处可重入，
/// 这个仓库已经在 `Supervisor` / `ContainerListStore` / `WhitelistUIStore` 上踩过三次同一条坑。
///
/// 若不校验，一次**迟到**的 `poll()` 结果落地时会用**更旧**的样本覆盖**更新**的 `latest`——
/// 界面上的 CPU%/内存数字会不定期地「倒退」一格。这里用 `epoch`（与 `Supervisor.deliver`
/// 同一条纪律）：每次 `poll()`/`reset()` 开始时递增并记下当时的值，`await` 之后只有
/// `epoch` 仍然一致的结果才会被采纳，迟到的一律无声丢弃。
///
/// ## poll 失败：保留上次历史，不清空
///
/// 一次 XPC 抖动不该让界面从「有数字」闪回「没有数字」——那比不刷新还吵。
/// `latest`/`previousSample` 在失败路径上原封不动。
public actor StatsCollector {

    private let client: any ContainerRuntimeClient
    private let id: ContainerID
    private let clock: any SupervisorClock
    private let sparklineLimit: Int

    private var previousSample: ContainerStatsSample?
    private var previousSampledAt: Date?
    private var sparkline: [Double] = []
    private var epoch = 0

    /// 最近一次成功应用的快照。首次 poll 之前是 `nil`（还没有任何数据，UI 显示占位）。
    public private(set) var latest: ContainerStatsSnapshot?

    public init(
        client: any ContainerRuntimeClient,
        id: ContainerID,
        clock: any SupervisorClock = SystemSupervisorClock(),
        sparklineLimit: Int = 60
    ) {
        precondition(sparklineLimit > 0, "sparklineLimit must be positive — invalid config is clamped here")
        self.client = client
        self.id = id
        self.clock = clock
        self.sparklineLimit = sparklineLimit
    }

    /// 取一次样本，算出新的 `latest`。首样本 CPU% 恒为 `nil`（没有前一个样本可比较）。
    public func poll() async {
        epoch += 1
        let capturedEpoch = epoch

        let sampledAt = await clock.now()

        guard let sample = try? await client.stats(id: id) else {
            // 失败：不动 `latest`/`previousSample`——保留上次历史。
            // （成功路径下面会验 epoch；失败路径本就什么都不改，epoch 校验没有额外意义。）
            return
        }

        guard capturedEpoch == epoch else { return }  // 迟到的结果：世界已经变了，闭嘴退出

        apply(sample: sample, sampledAt: sampledAt)
    }

    /// 窗口重开：新一轮 CPU% 又该从「首样本占位」起算，不能沿用上一轮窗口关闭前的旧样本
    /// （旧样本的时间戳早已过期，拿它算间隔会得到一个荒谬的 `interval`）。
    public func reset() {
        epoch += 1
        previousSample = nil
        previousSampledAt = nil
        sparkline = []
        latest = nil
    }

    // MARK: -

    private func apply(sample: ContainerStatsSample, sampledAt: Date) {
        let cpuPercent: Double?
        if let previousSample, let previousSampledAt {
            let interval = Duration.seconds(sampledAt.timeIntervalSince(previousSampledAt))
            cpuPercent = CPUPercentCalculator.percent(
                previous: previousSample.cpuUsageUsec,
                current: sample.cpuUsageUsec,
                interval: interval
            )
        } else {
            cpuPercent = nil  // 首样本：无从比较，占位
        }

        if let cpuPercent {
            sparkline.append(cpuPercent)
            if sparkline.count > sparklineLimit {
                sparkline.removeFirst(sparkline.count - sparklineLimit)
            }
        }

        previousSample = sample
        previousSampledAt = sampledAt

        latest = ContainerStatsSnapshot(
            cpuPercent: cpuPercent,
            memoryUsedBytes: sample.memoryUsageBytes,
            memoryLimitBytes: sample.memoryLimitBytes,
            cpuSparkline: sparkline
        )
    }
}
