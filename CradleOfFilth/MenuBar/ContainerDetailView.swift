import AppKit
import ContainerCore
import SwiftUI

/// 单个容器的详情。**env 逐行走 `SecretField`**——默认全打码，点击才展开。
///
/// 老实渲染 env = 密钥出现在屏幕、每一张截图、每一次录屏里（本机 `open-connector` 的 env 里
/// 就有 `OOMOL_CONNECT_ENCRYPTION_KEY`）。所以这个页面不存在「顺手把值显示出来」的路径：
/// 值的类型是 `SecretString`，要明文必须经过 `SecretField` 里那个显式的「显示」动作。
struct ContainerDetailView: View {

    let container: Container

    /// Day 13：生命周期动作。view 只拿闭包和状态——拒绝制、半失败区分全在
    /// `ContainerActionStore`（core，可测）；client 不进 view（裁决 #9）。
    let actionInProgress: ContainerActionStore.Action?

    /// 本容器的错误（Host 已按 id 取好——view 不做「是不是我的错误」的过滤）。
    let actionError: ContainerActionStore.ActionFailure?
    let onStop: @MainActor () async -> Void
    let onStart: @MainActor () async -> Void
    let onRestart: @MainActor () async -> Void

    /// 停止 / 重启前的确认（裁决 #2：文案要说明 supervisor 的竞态窗口）。启动不确认。
    private enum PendingConfirmation: Identifiable {
        case stop
        case restart

        var id: Self { self }

        /// 按钮文案 / 对话框标题共用的动词——判断收敛在这一处。
        /// `Button(verb, role:)` 与 `confirmationDialog(title, ...)` 都是 verbatim
        /// （传的是 `String` 变量），所以就地本地化（codex #6）。
        var verb: String {
            self == .stop ? String(localized: "Stop") : String(localized: "Restart")
        }
    }

    @State private var pendingConfirmation: PendingConfirmation?

    /// 打开日志 / stats 窗口用（Day 9 T7/T11）——两个都是独立 `Window` scene，见
    /// `CradleOfFilthApp`。
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Divider()

                environmentSection
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 320)
        .navigationTitle(container.id.rawValue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(container.id.rawValue)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)   // 容器名 / 镜像不是密钥，可选中复制

            LabeledContent("Image") {
                Text(container.image.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("Status") {
                Text(ContainerStatePresentation.label(for: container.state))
            }

            actionSection

            HStack(spacing: 12) {
                Button("View Logs") {
                    openAndActivate(LogWindowScene.windowID)
                }
                .buttonStyle(.link)

                Button("View Stats") {
                    openAndActivate(StatsWindowScene.windowID)
                }
                .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
    }

    /// 生命周期按钮组（Day 13 工作项 1）。running → 停止/重启；stopped → 启动；
    /// 其余瞬态（stopping 等）不给按钮——状态马上就变，按了也只是撞拒绝制。
    /// 进行中：spinner + 全部禁用（体验层；真正的防线是 store 的拒绝制）。
    @ViewBuilder
    private var actionSection: some View {
        HStack(spacing: 8) {
            if actionInProgress != nil {
                ProgressView()
                    .controlSize(.small)
            }

            switch container.state {
            case .running:
                Button("Stop") { pendingConfirmation = .stop }
                Button("Restart") { pendingConfirmation = .restart }
            case .stopped:
                Button("Start") {
                    // 启动不需要确认（计划拍板）：它不丢任何东西。
                    Task { await onStart() }
                }
            case .stopping, .unknown:
                EmptyView()
            }
        }
        .disabled(actionInProgress != nil)
        .padding(.top, 4)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingConfirmation?.verb ?? String(localized: "Stop"), role: .destructive) {
                let action = pendingConfirmation
                pendingConfirmation = nil
                Task {
                    switch action {
                    case .restart: await onRestart()
                    case .stop: await onStop()
                    case nil: break
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            // 裁决 #2 的措辞：稳态下不会被拉回，但 supervisor 正在自动拉起时后写胜。
            Text("A managed container won\u{2019}t auto-restart after you stop it manually (unless the container runtime restarts; if the supervisor is currently auto-starting, the container may be restarted right after).")
        }

        if let actionError {
            Text(ContainerActionPresentation.message(for: actionError))
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var confirmationTitle: String {
        // verb 已本地化；标题模式再本地化一次（key = "%@ %@?"），让问号标点随语言走。
        let verb = pendingConfirmation?.verb ?? String(localized: "Stop")
        return String(localized: "\(verb) \(container.id.rawValue)?")
    }

    /// 日志 / stats 两个窗口按钮共用的动作：先真正激活再按 id 打开
    /// （协作式激活拒绝 accessory 的裸 activate，见 `AppActivation`；
    /// `ContainerRow.onShowDetail` 同一条纪律）。
    private func openAndActivate(_ windowID: String) {
        AppActivation.activateForWindowUse()
        openWindow(id: windowID, value: container.id)
    }

    @ViewBuilder
    private var environmentSection: some View {
        Text("Environment Variables")
            .font(.headline)

        if container.environment.isEmpty {
            Text("(no environment variables)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // env 值默认全打码——点「显示」才展开，复制走 concealed pasteboard。
            VStack(alignment: .leading, spacing: 6) {
                ForEach(container.environment, id: \.key) { variable in
                    SecretField(label: variable.key, secret: variable.value)
                }
            }
        }
    }
}

/// 详情窗口的常量与宿主。**窗口按 `ContainerID` 打开**（`WindowGroup(for:)`），
/// 宿主再拿这个 id 去 store 里查当前的 `Container`——env（`SecretString`）就在那份快照里。
enum ContainerDetailScene {
    static let windowID = "container-detail"
}

/// 详情窗口的内容宿主。容器可能在窗口开着时被刷新掉（列表变了 / 运行时不在），
/// 所以每次都**按 id 现查**，查不到就老实说，而不是渲染一份陈旧的 env。
struct ContainerDetailHost: View {

    let model: AppModel
    let id: ContainerID?

    var body: some View {
        if let id, let container = lookup(id) {
            ContainerDetailView(
                container: container,
                actionInProgress: model.actions.actionInProgress(for: container.id),
                actionError: model.actions.error(for: container.id),
                onStop: { await model.actions.stop(id: container.id) },
                onStart: { await model.actions.start(id: container.id) },
                onRestart: { await model.actions.restart(id: container.id) }
            )
        } else {
            ContainerNotFoundPlaceholder(systemImage: "shippingbox", minWidth: 460, minHeight: 320)
        }
    }

    private func lookup(_ id: ContainerID) -> Container? {
        // 查找的那份「当前该显示的容器」由 core 决定（loaded / 挂掉后的旧快照），这里只做 first。
        model.containers.displayedContainers.first { $0.id == id }
    }
}
