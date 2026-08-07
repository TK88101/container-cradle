import ContainerCore
import SwiftUI

/// clone 窗口的常量。`WindowGroup(for: ContainerID.self)`：按源容器开，
/// 可同时 clone 两个不同源（同 Detail/Log/Stats，B 段 §3.2）。
enum CloneContainerWindowScene {
    static let windowID = "clone-container"
}

/// clone 窗口的宿主。store 随窗建（`@State`，按 `source` 构造，B 段 §3.3）：
/// 它的身份就是源 id，不存在「全局一份」。client 与 Log/Stats 窗口同源——
/// composition root 已持有的那份引用，不引入新的生命周期。
struct CloneContainerWindowHost: View {

    let model: AppModel
    let source: ContainerID?

    var body: some View {
        if let source {
            CloneContainerWindowView(
                model: model,
                store: ContainerCloneStore(source: source, client: model.client)
            )
        } else {
            ContainerNotFoundPlaceholder(systemImage: "shippingbox", minWidth: 460, minHeight: 320)
        }
    }
}

/// clone 窗口（Day 16 T9.7，能力 B）。**薄**：加载 / 提交全在 `ContainerCloneStore`（core，可测）。
///
/// ## env 只读 = 本版刻意（用户既裁定①，防轮回登记）
///
/// env 只做打码展示（复用 `SecretField`，零新增 reveal 调用点——扫描器数着），提交必然**原样克隆**——
/// `environmentOverride` 全程 nil。core 的 `setEnvironmentOverride` 已测但 UI 刻意不接线，
/// **不是死代码**：可编辑 env 是已裁定推迟的能力，接口留在 core 等下一版。
struct CloneContainerWindowView: View {

    let model: AppModel

    @State var store: ContainerCloneStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 400)
        .navigationTitle(Text("Clone \(store.source.rawValue)"))
        // `.task(id:)` 只在 id 变化时重跑；「重试」按钮的第二次 load 与它交错时，
        // 由 store 的 `loadGeneration` 令牌拦陈旧回写（B 段 codex #4）。
        .task(id: store.source) {
            await store.loadTemplate()
        }
    }

    /// loadState 三态都有渲染（DoD）。
    @ViewBuilder
    private var content: some View {
        switch store.loadState {
        case .loading:
            Section {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading the source container configuration…")
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let error):
            Section {
                FormErrorText(message: ContainerCreationPresentation.message(forCloneLoadFailure: error))

                Button("Retry") {
                    Task { await store.loadTemplate() }
                }
            }

        case .loaded(let template):
            loadedForm(template)
        }
    }

    @ViewBuilder
    private func loadedForm(_ template: ContainerCloneTemplate) -> some View {
        @Bindable var store = store

        Section {
            LabeledContent("Source") {
                Text(store.source.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("Image") {
                Text(template.image.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            // 挂载只读摘要（用户既裁定：clone 不编辑挂载；bind/tmpfs 本来就无法从零表达）。
            LabeledContent("Mounts") {
                Text(
                    "\(template.mountSummary.volumeCount) volumes, \(template.mountSummary.bindCount) bind, \(template.mountSummary.tmpfsCount) tmpfs"
                )
            }

            TextField(text: $store.newName, prompt: Text(verbatim: "my-clone")) {
                Text("New name")
            }
            // 这个框在 `Form` 里，实测**本来就有名**（标签经 AXTitleUIElement 关联）。
            // 显式补一遍不是冗余：可访问名称有没有，取决于**祖先里有没有 Form**——
            // 同一个 initializer、同一句 `.labelsHidden()`，在 Form 里有名、在 VStack 里无名。
            // 而「祖先是谁」静态扫描判不出（跨文件、跨 @ViewBuilder），所以守卫对 TextField 一律要求显式 label。
            // 把这行删掉，它今天仍然有名；但哪天这个 Section 被搬出 Form 就会静默失名，没有任何东西会报警。
            .accessibilityLabel(Text("New name"))
        }

        Section("Environment Variables") {
            if template.environment.isEmpty {
                Text("(no environment variables)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 只读打码展示，复制走 concealed pasteboard——与详情页同一个组件、
                // 同一份明文出口预算（`SecretField` 那两处，不新增）。
                ForEach(template.environment, id: \.key) { variable in
                    SecretField(label: variable.key, secret: variable.value)
                }
            }
        }

        Section {
            HStack {
                if store.phase == .submitting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Clone") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                // disabled 只是体验层（真防线是 store 的单飞门）。
                .disabled(store.phase == .submitting)
            }

            if case .failed(let failure) = store.phase {
                FormErrorText(message: ContainerCreationPresentation.message(for: failure))
            }
        }
    }

    private func submit() async {
        guard await store.submit() else { return }

        switch store.phase {
        case .succeeded:
            // 成功：刷新列表 → reset → 关窗（B 段 §3.5 表）。克隆出来的容器是 stopped，
            // 刷新后的列表会如实显示它。
            await model.containers.refresh()
            store.reset()
            dismiss()

        case .editing, .submitting, .failed:
            break   // 失败留在窗内显示红字；reset 会清掉用户正要看的失败态，不做
        }
    }
}
