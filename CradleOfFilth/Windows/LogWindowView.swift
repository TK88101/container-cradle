import AppKit
import ContainerCore
import SwiftUI

/// 日志窗口的常量与宿主，跟 `ContainerDetailScene`/`ContainerDetailHost` 同一套路
/// （`WindowGroup(id:for:)` 独立窗口，宿主按 id 现查）。
enum LogWindowScene {
    static let windowID = "container-logs"
}

struct LogWindowHost: View {

    let model: AppModel
    let id: ContainerID?

    var body: some View {
        if let id {
            LogWindowView(id: id, model: model)
        } else {
            ContainerNotFoundPlaceholder(systemImage: "doc.text", minWidth: 520, minHeight: 360)
        }
    }
}

/// follow / 暂停 / 搜索 / 清屏。**view 只绑定、只渲染**——判断（脱敏、有界缓冲、搜索匹配、
/// 换代检测）全部住 `LogWindowStore` 转发的核心层。
struct LogWindowView: View {

    let id: ContainerID
    let model: AppModel

    @State private var store: LogWindowStore

    init(id: ContainerID, model: AppModel) {
        self.id = id
        self.model = model
        _store = State(
            wrappedValue: LogWindowStore(
                id: id,
                client: model.client,
                containers: model.containers,
                currentGeneration: { model.currentGeneration }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            statusBanner

            logList
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle(id.rawValue)
        .task { store.open() }
        .onDisappear { store.close() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)
                // `TextField` 的 title 在 macOS 上是 **placeholder**，不是名称——
                // 非空却照样无名（实测三条信道全空），而这个框不在 `Form` 里，
                // 没有任何东西替它关联标签。名称只能显式给。
                .accessibilityLabel(Text("Search logs"))
                .frame(maxWidth: 220)

            Spacer()

            Toggle(isOn: $store.isPaused) {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
            }
            .toggleStyle(.button)
            // 名称必须随状态走：这个按钮按下去做的事是相反的两件，
            // 一直念「暂停」会让已暂停的用户以为再按一次还是暂停。
            // 三元写在 `Text(…)` 里面（不是 `.accessibilityLabel` 的顶层），
            // 两支都是 `String(localized:)` 字面量 → 四语可抽取。
            .accessibilityLabel(Text(store.isPaused
                ? String(localized: "Resume auto-scroll")
                : String(localized: "Pause auto-scroll")))
            .help(store.isPaused
                ? String(localized: "Resume auto-scroll")
                : String(localized: "Pause auto-scroll (logs keep following in the background)"))

            Button {
                copyAll()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(Text("Copy all logs"))
            .help("Copy all (redacted)")

            Button {
                store.clear()
            } label: {
                Image(systemName: "trash")
            }
            // 默认名来自 SF Symbol，是 "Trash"——描述的是图标画的东西，不是这个按钮干的事
            // （它清的是本窗口的日志缓冲，不删任何东西）。同 `Go Down` 一类的语义错。
            .accessibilityLabel(Text("Clear"))
            .help("Clear")

            Button {
                store.open()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Reopen"))
            .help("Reopen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch store.phase {
        case .resolvingRedaction, .following:
            EmptyView()

        case .unresolvedRedaction:
            bannerWithDivider(
                systemImage: "lock.trianglebadge.exclamationmark",
                text: String(localized: "Cannot confirm the redaction scope; logs are hidden for now · Retry")
            )

        case .generationStale:
            bannerWithDivider(
                systemImage: "arrow.triangle.2.circlepath",
                text: String(localized: "The runtime changed generation; the log stream may be stale · Reopen")
            )

        case .streamEnded(let reason):
            bannerWithDivider(
                systemImage: "stop.circle",
                text: reason.map { String(localized: "Log stream ended (\($0)) · Reopen") }
                    ?? String(localized: "Log stream ended · Reopen")
            )
        }
    }

    private func bannerWithDivider(systemImage: String, text: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.orange)

                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button("Retry") { store.open() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
        }
    }

    /// 固定的底部滚动锚点。**为什么不用每行的 `line.id` 当滚动目标**：`line.id` 单调递增、
    /// 每行都不一样，`ScrollViewReader` 的 proxy 会随「见过的 id」无界累积内部注册表——
    /// 于是 follow 一个 chatty 容器时，内存随**产出行数**线性涨（实测 ~0.9KB/行、10 分钟 +18MB），
    /// 且关窗不释放。环形缓冲把行数封在 5000，但这个注册表不受它约束。
    /// → proxy 永远只认这一个固定 id，注册表不增长。（Day 9 内存里程碑的真机测试抓到的）
    private static let bottomAnchorID = "log-bottom-anchor"

    /// 复制全部日志到剪贴板。**复制的是 `store.lines`——已经过 `LogRedactor` 脱敏的文本**
    /// （`RedactedLogLine`），所以这条路不会把明文密钥送进剪贴板（D2）。
    /// 内存中性：点一下才拼一次字符串，用完即释放。
    ///
    /// 这是去掉 `.textSelection(.enabled)` 后的补偿——逐行选中会让每一产出行的选择态控制器
    /// 随滚动无界累积（Day 9 内存里程碑真机测试抓到的：10 分钟 +18MB，关窗不释放）。
    /// 用「一键复制全部」换掉「逐行选中」：既保住「把日志捞出去」的核心需求，又不留那个泄漏面。
    private func copyAll() {
        let text = store.lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var logList: some View {
        // C1：算一次，两处（`ForEach` + `onChange` 的追踪值）复用——`filteredLines` 是
        // O(n) 的 Unicode 子串搜索（`LogFilter.apply`，n 最多 5000），每轮轮询都触发一次
        // body 重算，读两遍就是算两遍。
        let filtered = store.filteredLines

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 固定底部锚点：滚动只认它，不给每行单独 `.id()`（那会让 proxy 无界累积）。
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            // 暂停时不追新——那正是「暂停」在 view 层的全部含义（D-C'）：
            // `LogTailer` 底下照样在收行，只是这里不再把新行滚到眼前。
            .onChange(of: filtered.last?.id) { _, newValue in
                guard !store.isPaused, newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }
}
