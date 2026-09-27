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

            if let status = RuntimeUpdatePresentation.statusText(for: store.state) {
                statusLine(status)
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
