import ContainerCore
import TerminalProgress
import Testing

@testable import ContainerRuntime

/// `PullMapper`：把上游 `[ProgressUpdateEvent]` 累积成 domain `PullProgress`（§3.3 / T5）。
///
/// 守两件事：
/// 1. **三档降级正确**（字节 / 项 / 不确定），且档位优先级忠于 `PullProgress.display`。
/// 2. **add* 增量族与 set* 全量族都处理**——漏 add* 会重演 T2b 的「字节假 0」
///    （spike 初版只数 set*，把实际走增量族的字节流读成 0）。这条有专门的「仅 add*」回归测试守。
@Suite("PullMapper：进度事件 → PullProgress")
struct PullMapperTests {

    // MARK: 字节档（顶档 A）

    @Test("字节档：set* 全量族")
    func byteTierViaSetFamily() {
        let progress = PullMapper.progress(from: [.setTotalSize(1000), .setSize(250)])
        #expect(progress.display == .fraction(0.25))
    }

    /// ★ T2b 回归守卫：进度实际走**增量族**。漏了 add* 这条会退回「字节假 0」。
    @Test("字节档：仅 add* 增量族也能累出百分比")
    func byteTierViaAddFamilyOnly() {
        let progress = PullMapper.progress(from: [.addTotalSize(1000), .addSize(250), .addSize(250)])
        #expect(progress.bytes == 500)
        #expect(progress.totalBytes == 1000)
        #expect(progress.display == .fraction(0.5))
    }

    // MARK: 项档

    @Test("项档：set* 全量族")
    func itemTierViaSetFamily() {
        let progress = PullMapper.progress(from: [.setTotalItems(7), .setItems(3)])
        #expect(progress.display == .items(count: 3, total: 7))
    }

    @Test("项档：仅 add* 增量族")
    func itemTierViaAddFamilyOnly() {
        let progress = PullMapper.progress(from: [.addTotalItems(7), .addItems(1), .addItems(2)])
        #expect(progress.display == .items(count: 3, total: 7))
    }

    // MARK: 混合档 — 字节优先于项（忠于 PullProgress.display 的档位次序）

    @Test("混合档：字节与项都有时，字节档赢")
    func mixedTierBytesWinOverItems() {
        let progress = PullMapper.progress(from: [
            .setTotalItems(7), .setItems(3),
            .setTotalSize(1000), .setSize(400),
        ])
        #expect(progress.display == .fraction(0.4))
    }

    // MARK: 不确定档 + phase 捕获

    @Test("不确定档：无任何计数 → 转圈；phase 取 setDescription")
    func indeterminateWithPhase() {
        let progress = PullMapper.progress(from: [.setDescription("Fetching image"), .setItemsName("blobs")])
        #expect(progress.display == .indeterminate)
        #expect(progress.phase == "Fetching image")
    }

    @Test("phase 取最后一个 setDescription")
    func phaseTracksLastDescription() {
        let progress = PullMapper.progress(from: [
            .setDescription("Fetching image"),
            .setDescription("Unpacking image"),
        ])
        #expect(progress.phase == "Unpacking image")
    }

    // MARK: 跨批累积（真实路径：每次 XPC 回调是一批事件）

    @Test("跨批累积：add* 在多批之间累加")
    func crossBatchAccumulation() {
        let step1 = PullMapper.folding(PullMapper.initial, with: [.addTotalSize(1000)])
        let step2 = PullMapper.folding(step1, with: [.addSize(400)])
        let accumulated = PullMapper.folding(step2, with: [.addSize(100)])

        #expect(accumulated.bytes == 500)
        #expect(accumulated.totalBytes == 1000)
        #expect(accumulated.display == .fraction(0.5))
    }

    // MARK: 忽略族不污染状态

    @Test("task/subDescription/itemsName/custom 被忽略，不污染计数与 phase")
    func ignoredFamiliesDoNotCorrupt() {
        let progress = PullMapper.progress(from: [
            .setTotalItems(5), .setItems(2),
            .addTasks(3), .setTasks(4), .addTotalTasks(9), .setTotalTasks(9),
            .setSubDescription("for platform arm64"),
            .setItemsName("blobs"),
            .custom("x"),
        ])
        #expect(progress.display == .items(count: 2, total: 5))
        #expect(progress.phase == "")
    }

    // MARK: 空输入

    @Test("空事件流 → initial 透传，不确定档")
    func emptyEventsPassthrough() {
        #expect(PullMapper.folding(PullMapper.initial, with: []) == PullMapper.initial)
        #expect(PullMapper.progress(from: []).display == .indeterminate)
    }
}
