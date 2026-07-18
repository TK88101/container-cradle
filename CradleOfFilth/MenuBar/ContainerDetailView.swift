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

            LabeledContent("镜像") {
                Text(container.image.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("状态") {
                Text(ContainerStatePresentation.label(for: container.state))
            }

            HStack(spacing: 12) {
                Button("查看日志") {
                    openAndActivate(LogWindowScene.windowID)
                }
                .buttonStyle(.link)

                Button("查看 stats") {
                    openAndActivate(StatsWindowScene.windowID)
                }
                .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
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
        Text("环境变量")
            .font(.headline)

        if container.environment.isEmpty {
            Text("（没有环境变量）")
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
            ContainerDetailView(container: container)
        } else {
            ContainerNotFoundPlaceholder(systemImage: "shippingbox", minWidth: 460, minHeight: 320)
        }
    }

    private func lookup(_ id: ContainerID) -> Container? {
        // 查找的那份「当前该显示的容器」由 core 决定（loaded / 挂掉后的旧快照），这里只做 first。
        model.containers.displayedContainers.first { $0.id == id }
    }
}
