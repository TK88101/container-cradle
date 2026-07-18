import AppKit
import ContainerCore
import SwiftUI

/// 菜单栏点开后的整块内容。
///
/// Day 7 起它不只是「看容器」：**每一行前面那个勾选框，就是白名单**——
/// 勾上的容器会在运行时回来时被自动拉起。那是这个 App 存在的理由，
/// 所以它必须在最显眼的地方，而不是藏在一个「设置」窗口里。
struct MenuBarRootView: View {

    let model: AppModel

    @State private var loginItem = LoginItem()

    /// 打开容器详情窗口用（详情是独立 `Window` scene，见 `CradleOfFilthApp`）。
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            SupervisorSection(
                state: model.status.state,
                notice: model.status.lastNotice,
                onForceReconcile: { Task { await model.forceReconcile() } }
            )

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: 320)
        // 菜单每次打开都重新拉一次：没有事件流（`XPCRoute.containerEvent` 从未接线），
        // 「打开时刷新」是此刻唯一能保证数据不陈旧的时机。
        // 白名单也重读一次：用户可能刚在 Finder 里手改了那个 JSON。
        //
        // ★ **白名单必须先读，容器列表后拉**（codex review 抓到的）。
        //
        // 反过来的话，容器行会在白名单还是空的时候就渲染出来——用户在那个窗口里
        // 点一下勾选框，`setManaged` 就基于**空列表**算出新快照落盘：
        // **他原有的白名单条目被整份洗掉了**。而白名单是配置资产，不是缓存。
        //
        // 读本地小 JSON 本来就比一次 XPC 快，这个顺序不花任何代价。
        .task {
            loginItem.refresh()   // 用户可能刚在「系统设置 → 登录项」里改过

            await model.whitelist.load()
            await model.containers.refresh()
        }
        // ★ supervisor 一动，列表就重拉（codex review 抓到的）。
        //
        // 没有事件流（`XPCRoute.containerEvent` 从未接线），容器状态只能靠拉。
        // 而 supervisor 刚刚**亲手改变了容器的状态**——它拉起了容器，列表却还显示「已停止」。
        //
        // 挂在状态变化上、而不是挂在「立即启动」那个按钮的回调里：
        // - 按钮回调返回时 reconcile **还没跑完**，那时 refresh 拿到的照样是旧状态；
        // - 自动路径（运行时回来 → 自动拉起）有一模一样的问题，而它根本没有按钮可挂。
        //
        // 心跳不会打扰它：状态没变的那些轮次 supervisor 根本不投快照（见 `Supervisor.handle`）。
        .onChange(of: model.status.state) {
            Task { await model.containers.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text("Containers")
                .font(.headline)

            Spacer()

            Button {
                Task { await model.containers.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.containers.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

        case .loaded(let containers):
            if containers.isEmpty {
                emptyState
            } else {
                rows(containers, isStale: false)
            }

        case .failed(let error, let lastKnown):
            VStack(alignment: .leading, spacing: 0) {
                RuntimeDownBanner(error: error, hasStaleData: !lastKnown.isEmpty)

                // 旧数据照常显示（灰掉）：运行时挂掉时把列表清空，
                // 用户会以为容器被删了。见 `ContainerListStore.LoadState.failed`。
                if !lastKnown.isEmpty {
                    rows(lastKnown, isStale: true)
                }
            }
        }
    }

    private func rows(_ containers: [Container], isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(containers) { container in
                ContainerRow(
                    container: container,
                    isStale: isStale,
                    isManaged: model.whitelist.isManaged(container.id),
                    onToggleManaged: { managed in
                        model.whitelist.setManaged(container.id, managed)
                    },
                    onShowDetail: {
                        // 先真正激活（协作式激活拒绝 accessory 的裸 activate，
                        // 见 AppActivation），窗口才不会落到别的 App 后面、键盘才跟得上。
                        AppActivation.activateForWindowUse()
                        openWindow(id: ContainerDetailScene.windowID, value: container.id)
                    }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        Text("No containers")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 落盘失败必须能被看见：静默失败 = 用户以为配好了，
            // 而 supervisor 下次开机什么都不会拉。
            if let saveError = model.whitelist.saveError {
                errorText(String(localized: "Failed to save whitelist: \(saveError)"))
            }

            Toggle(
                "Start at login",
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.callout)
            .help("On Mac restart, the app must start before apiserver to catch the \u{201C}runtime is back\u{201D} edge")

            if let error = loginItem.error {
                errorText(String(localized: "Failed to set login item: \(error)"))
            }

            // M5（Day 10）：volume / image 管理入口。
            HStack {
                Button("Manage Volumes…") {
                    openManagementWindow(VolumesWindowScene.windowID)
                }
                .buttonStyle(.borderless)

                Button("Manage Images…") {
                    openManagementWindow(ImagesWindowScene.windowID)
                }
                .buttonStyle(.borderless)

                Spacer()
            }

            HStack {
                Button("Show whitelist file") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.whitelistURL])
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 两条错误提示（白名单落盘失败 / 自启设置失败）长得一样，排版只写一份。
    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 打开窗口前先真正激活（见 `AppActivation`；`ContainerDetailView.openAndActivate`
    /// 同一条纪律；那份是带 value 的窗口，这份是无 value 的单实例窗口，
    /// 签名不同所以各自一份）。
    private func openManagementWindow(_ windowID: String) {
        AppActivation.activateForWindowUse()
        openWindow(id: windowID)
    }
}
