import ContainerCore
import SwiftUI

/// 菜单里的 apple/container 更新区（Day 22）：版本行 + 「检查更新」、状态行、可用时的三个决定、失败时的「启动运行时」、
/// A9 的「未经测试」提示、自动检查开关。
///
/// **判断一行都不在这儿**：状态行文案、要不要显示提示全由 core 的 `RuntimeUpdatePresentation` 给出（有测试）；
/// 按钮直接调 store 的方法（单飞在 store 里）。
///
/// 排版预算（`MenuBarRootView` 的 296pt）：每行最多两个按钮——ja 的「今すぐアップデート」+「このバージョンをスキップ」
/// 已接近上限，所以「あとで」与「リリースノート」另起一行。改文案后要回去四语截图取证（T12）。
struct RuntimeUpdateSection: View {

    let store: RuntimeUpdateStore
    let testedVersion: RuntimeVersion

    @Environment(\.openURL) private var openURL

    /// 「这个 deadline 已经过了」：挂 TimelineView 的条件里实际读它，写它就会让 body 重新求值，摘掉每秒刷新（Plan 2026-10-23 §2.5）。
    /// 只对同一个 deadline 生效——deadline 变了（重新检查、再次限流），旧标记自然失效。
    @State private var expiredDeadline: Date?

    private var refreshDeadline: Date? {
        RuntimeUpdatePresentation.refreshDeadline(for: store.state, recheckFailure: store.recheckFailure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "apple/container \(store.lastKnownInstalled?.description ?? "—")")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Check for Updates") { store.checkForUpdates() }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy || !store.isPrimaryInstance || store.isTerminating)
            }

            refreshing { now in
                if let status = RuntimeUpdatePresentation.statusText(for: store.state, now: now) {
                    statusLine(status)
                }
                if let failure = store.recheckFailure {
                    Text(RuntimeUpdatePresentation.recheckNote(failure, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions

            if let note = RuntimeUpdatePresentation.testedNote(installed: store.lastKnownInstalled, tested: testedVersion) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                "Automatically check for updates",
                isOn: Binding(
                    get: { store.isAutomaticCheckEnabled },
                    set: { store.isAutomaticCheckEnabled = $0 }
                )
            )
            .toggleStyle(.checkbox)
            .font(.callout)
            // 退出交接期间不接受改设置（R7；store 里也挡了写盘）。
            .disabled(!store.isPrimaryInstance || store.isTerminating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 挂在始终存在的外层：Timeline 分支会随条件消失，挂在那里 task 的生命周期就说不清了。
        .task(id: refreshDeadline) { await markExpired(refreshDeadline) }
    }

    /// 睡到 deadline 再标记它已过期。wall-clock 的 deadline 不能无损换成 `ContinuousClock`：
    /// 每次至多睡 1 s、醒来按 `Date()` 重算剩余时间，系统时间被调动时误差上限约 1 s，与每秒刷新的粒度一致（codex R2-P1）。
    /// 被取消（deadline 变了 / 菜单关了）⇒ 什么都不写。
    private func markExpired(_ deadline: Date?) async {
        guard let deadline else { return }
        while case let remaining = deadline.timeIntervalSinceNow, remaining > 0 {
            do { try await Task.sleep(for: .seconds(min(remaining, 1))) } catch { return }
        }
        guard !Task.isCancelled else { return }
        expiredDeadline = deadline
    }

    /// 文案会到点改口（限流解除）时挂 `TimelineView` 重绘；文案必须在 closure 里用 `context.date` 现算——
    /// 外面先算好的字符串包进 Timeline，到点重绘的仍是旧字符串（Plan 2026-10-21 §2.2 R1-1）。挂不挂由 core 判断。
    /// 用每秒一次的 periodic，不用 `.explicit([until])`（Day 24 真机诊断日志实测）：菜单栏弹窗里 explicit 只在打开时渲染，
    /// 到点那次从不触发；且只给 `[until]` 时首次渲染的 `context.date` 就是 until 本身，没到点就已改口。
    /// 只在限流态、且解除时刻 + 1 s 之前挂（Day 26：改口之后摘掉，见 `markExpired`）；弹窗关着时不渲染。
    @ViewBuilder
    private func refreshing<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let deadline = refreshDeadline, deadline != expiredDeadline,
           RuntimeUpdatePresentation.needsPeriodicRefresh(for: store.state, recheckFailure: store.recheckFailure, now: Date()) {
            // 显式左对齐：closure 里的多行默认被居中包起来，改口后行宽变化，较短的状态行会被挤到中间（真机截图实测）。
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) { content(context.date) }
            }
        } else {
            content(Date())
        }
    }

    /// 升级进行中带已用时间（真下载 118 MB 实测 206 秒——没有时间读数的「下载中…」看起来像卡死）。
    @ViewBuilder
    private func statusLine(_ status: String) -> some View {
        if case .updating = store.state, let started = store.stageStartedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                styled(Text(verbatim: "\(status) \(RuntimeUpdatePresentation.elapsed(from: started, to: context.date))"))
            }
        } else {
            styled(Text(verbatim: status))
        }
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(.caption)
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        switch store.state {
        case .failed, .checkFailed: .red
        case .available: .accentColor
        default: .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch store.state {
        case .available(_, let release):
            HStack(spacing: 8) {
                Button("Update Now") { store.install() }
                    .buttonStyle(.borderless)
                Button("Skip This Version") { store.skip() }
                    .buttonStyle(.borderless)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Later") { store.later() }
                    .buttonStyle(.borderless)
                Button("Release Notes") { openURL(release.releasePageURL) }
                    .buttonStyle(.borderless)
                Spacer()
            }
        default:
            EmptyView()
        }
        // 跟着「未解决的复原义务」走，不跟着 state 走：失败态会被之后的检查覆盖，义务不会（R2 E）。
        // 显示与否、标题只看 `manualRestore` 一个来源（codex R5 补评 D）；两个标题调的是同一个动作。
        // 两个独立的字面量，不用三目：三目会被推断成 `String` 重载，绕开本地化。
        switch store.manualRestore {
        case .startRuntime?:
            Button("Start Runtime") { store.startRuntime() }
                .buttonStyle(.borderless)
        case .startRemainingContainers?:
            Button("Start Remaining Containers") { store.startRuntime() }
                .buttonStyle(.borderless)
        case nil:
            EmptyView()
        }
    }
}
