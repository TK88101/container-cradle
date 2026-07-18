import ContainerCore
import SwiftUI

/// stats 窗口的常量与宿主，跟 `ContainerDetailScene`/`LogWindowScene` 同一套路。
enum StatsWindowScene {
    static let windowID = "container-stats"
}

struct StatsWindowHost: View {

    let model: AppModel
    let id: ContainerID?

    var body: some View {
        if let id {
            StatsWindowView(id: id, model: model)
        } else {
            ContainerNotFoundPlaceholder(systemImage: "chart.line.uptrend.xyaxis", minWidth: 360, minHeight: 260)
        }
    }
}

/// CPU% 数字 + 历史折线，内存 used/limit。**view 只渲染**——差分数学、首样本占位、
/// sparkline 有界化全部是 `StatsCollector` 算好的 `ContainerStatsSnapshot`，这里不重算。
///
/// ## 为什么没有「内存 sparkline」
///
/// 核心层（`ContainerStatsSnapshot`）只维护 `cpuSparkline`——内存没有历史序列，
/// 只有当前 used/limit 两个瞬时值。渲染一条编出来的内存历史线，会是一份假造的曲线，
/// 比不画更糟；所以内存这里只是两个数字。
struct StatsWindowView: View {

    let id: ContainerID
    let model: AppModel

    @State private var store: StatsWindowStore

    init(id: ContainerID, model: AppModel) {
        self.id = id
        self.model = model
        _store = State(wrappedValue: StatsWindowStore(id: id, client: model.client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(id.rawValue)
                .font(.system(.title3, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            cpuSection
            memorySection

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 280)
        .navigationTitle(id.rawValue)
        .task { store.start() }
        .onDisappear { store.stop() }
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU")
                .font(.headline)

            // 首样本恒为 nil → 占位 `--`，不是 `0%`（P2-3：0% 是「量到了，真的空转」，
            // 两者混为一谈会让用户把「还没测出来」读成「容器不干活」）。
            Text(cpuPercentText)
                .font(.system(.largeTitle, design: .rounded))

            Sparkline(values: store.snapshot?.cpuSparkline ?? [])
                .frame(height: 40)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(.headline)

            Text(memoryText)
                .font(.system(.body, design: .monospaced))
        }
    }

    // CPU%/内存占位文案（nil → "--" vs 0 → "0.0%" 的区分是判断，不是格式）住
    // `StatsPresentation`（core，可测）——同 `ContainerStatePresentation` 的纪律，
    // 判断留在 view 里就是零测试。
    private var cpuPercentText: String {
        StatsPresentation.cpuPercentText(store.snapshot?.cpuPercent)
    }

    private var memoryText: String {
        StatsPresentation.memoryText(
            usedBytes: store.snapshot?.memoryUsedBytes,
            limitBytes: store.snapshot?.memoryLimitBytes
        )
    }
}

/// CPU% 历史的极简折线图。纯展示，不做任何数值判断——数据本身（有界、首样本占位）
/// 已经是 `StatsCollector` 算好的 `cpuSparkline`。
private struct Sparkline: View {

    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            let maxValue = max(values.max() ?? 0, 1)
            let stepX = size.width / CGFloat(values.count - 1)

            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let y = size.height - (CGFloat(value / maxValue) * size.height)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
