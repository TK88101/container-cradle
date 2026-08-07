import AppKit
import ContainerCore
import SwiftUI

/// 镜像管理窗口的常量。单实例 `Window`，同 `VolumesWindowScene` 的理由。
enum ImagesWindowScene {
    static let windowID = "images"
}

/// 镜像管理窗口（Day 10 M5）。infra 镜像（vminit/builder）在 ACL 内已被过滤，
/// 这里**根本看不见**；`deletionEnabled == false`（过滤非权威）时删除按钮全体禁用
/// ——但那只是 UX，真正的防线在 ACL 的 `deleteImage` guard（★R3）。
/// 二次确认走 `confirmationDialog`（镜像可重新 pull，非「不可挽回」档，不打名字）。
struct ImagesWindowView: View {

    let model: AppModel

    private var store: ImageListStore { model.images }

    @State private var pendingDeletion: ImageSummary?

    /// pull sheet 的显隐（Day 16 T9.8）。态机本体常驻 `AppModel.pull`——sheet 关了 pull 照跑，
    /// 重开 sheet 看到的是当前进度，不是从头再来。
    @State private var pullSheetShown = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            refreshFailureBanner

            deletionDisabledBanner

            content
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle("Images")
        .task { await store.refresh() }
        .sheet(isPresented: $pullSheetShown) {
            PullImageSheet(model: model)
        }
        .confirmationDialog(
            "Delete image?",
            isPresented: confirmShown,
            presenting: pendingDeletion
        ) { image in
            Button("Delete \(image.reference.rawValue)", role: .destructive) {
                pendingDeletion = nil
                Task { await store.deleteImage(image) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { image in
            Text("This will delete the local data for \(image.reference.rawValue) (\(image.shortDigest)). The image can be pulled again.")
        }
        .alert("Deletion failed", isPresented: deleteFailedShown) {
            Button("OK", role: .cancel) { store.dismissDeletionFailure() }
        } message: {
            Text(deleteFailedReason)
        }
    }

    // MARK: - 顶栏 / 状态条

    private var toolbar: some View {
        HStack {
            Text("\(store.displayedImages.count) images")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            // Day 16 T9.8：App 内 pull 入口（能力 C 档 A，公开镜像、无认证）。
            Button("Pull Image…") {
                pullSheetShown = true
            }
            .buttonStyle(.borderless)

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            // 理由同 MenuBarRootView 的刷新按钮：SF Symbol 的默认名是 Apple 的字符串，不是我们的。
            .accessibilityLabel(Text("Refresh"))
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var refreshFailureBanner: some View {
        if case .failed = store.state {
            Text("Refresh failed — showing the last successful list")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    /// D-C fail-closed 的可见形态：删不了就明说为什么，不是按钮悄悄变灰。
    ///
    /// **判据来自 core**（`deletionBlockReason`，那边有真值表测试），view 只做分派。
    /// 三档必须分开：它们把用户带向**完全不同的排查方向**。原先三档共用一句
    /// 「配置加载失败」，其中两档是错的——运行时没起来，却让用户去翻配置文件。
    ///
    /// 穷尽 `switch`：`ImageDeletionBlockReason` 将来加 case，这里编译不过。
    /// app target 没有测试 target（CLAUDE.md），能替我们数分支的只剩编译器。
    @ViewBuilder
    private var deletionDisabledBanner: some View {
        switch store.deletionBlockReason {
        case nil, .stillLoading:
            // `.stillLoading` 刻意不出横幅：此时列表本就是空的 + `ProgressView` 在转，
            // 没有任何按钮在「悄悄变灰」，再加一条 loading 横幅是重复信道；
            // 而对「永久挂起」它也帮不上忙（挂起时它同样只是一直显示）——那条由超时兜。
            EmptyView()

        case .noSnapshotYet:
            banner(Text("The image list has never loaded (the runtime may not be running); deletion is disabled"))

        case .filterNotAuthoritative:
            banner(Text("Cannot confirm the system-image filter (config failed to load); deletion is disabled"))
        }
    }

    private func banner(_ text: Text) -> some View {
        text
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if store.displayedImages.isEmpty {
            emptyState
        } else {
            List(store.displayedImages) { image in
                imageRow(image)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Spacer()
        if case .loading = store.state {
            ProgressView()
        } else {
            Text("No images")
                .foregroundStyle(.secondary)
        }
        Spacer()
    }

    private func imageRow(_ image: ImageSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.reference.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .truncationMode(.middle)
                    .lineLimit(1)

                Text(image.shortDigest)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDeleting(image) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(role: .destructive) {
                    pendingDeletion = image
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!store.deletionEnabled || deletionInFlight)
                // 每行一个 trash，默认名全是 "Trash"——读屏分不清删的是哪个镜像。
                // ref 已经在同一行明文渲染着，拿它当名字不泄漏任何新信息。
                .accessibilityLabel(Text("Delete image \(image.reference.rawValue)"))
                .help("Delete the image's local data (can be pulled again)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 绑定

    private var confirmShown: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { shown in
                if !shown { pendingDeletion = nil }
            }
        )
    }

    private var deleteFailedShown: Binding<Bool> {
        Binding(
            get: {
                if case .failed = store.deletionFlow { true } else { false }
            },
            set: { shown in
                if !shown { store.dismissDeletionFailure() }
            }
        )
    }

    private var deleteFailedReason: String {
        if case .failed(_, let reason) = store.deletionFlow { reason } else { "" }
    }

    private var deletionInFlight: Bool {
        if case .deleting = store.deletionFlow { true } else { false }
    }

    private func isDeleting(_ image: ImageSummary) -> Bool {
        if case .deleting(let target) = store.deletionFlow { target == image } else { false }
    }
}

/// App 内 pull 的 sheet（Day 16 T9.8，能力 C 档 A）。**薄**：态机全在 `ImagePullStore`
/// （core，可测）；文案全在 `ImagePullPresentation` / `PullProgress.display`。
///
/// pull 属镜像管理语境，**不开第三个顶层窗口**（B 段 §3.2）：完成即刷新同窗列表
/// （`AppModel` 已把 `onCompleted` 注入为 `images.refresh()`）。
private struct PullImageSheet: View {

    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var referenceText = ""

    private var pull: ImagePullStore { model.pull }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull Image")
                .font(.headline)

            HStack {
                TextField(
                    text: $referenceText,
                    prompt: Text(verbatim: "docker.io/library/nginx:latest")
                ) {
                    Text("Image")
                }
                .labelsHidden()
                // 不在 `Form` 里 → 标签不会被关联到控件，实测三条名称信道全空。
                // 注意这里连 title 形参都没有：label 闭包 + `.labelsHidden()` 在非 Form 容器里
                // 同样不产生名称——Create 窗里一模一样的写法却有名，差别只在祖先有没有 Form。
                .accessibilityLabel(Text("Image reference to pull"))
                .font(.system(.body, design: .monospaced))
                .onSubmit { startPull() }

                Button("Pull") { startPull() }
                    .buttonStyle(.borderedProminent)
                    // pulling / cancelling 中禁用（呼应 core 单飞门，UI 只是体验层）；
                    // ref 合法性判据 = `ImageRef.init`（domain 单点，不在 view 抄规则）。
                    .disabled(isBusy || ImageRef(referenceText) == nil)
            }

            statusSection

            HStack {
                Spacer()

                if case .pulling = pull.state {
                    Button("Cancel") {
                        pull.cancel()   // 被放弃的 ref 由 store 记（lastAbandonedReference）
                    }
                }

                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    private var isBusy: Bool {
        switch pull.state {
        case .pulling, .cancellingForeground: true
        case .idle, .failed, .done: false
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        // 状态行文案住 core（穷尽 switch 在那边守）；失败态标红。
        Text(ImagePullPresentation.statusLabel(for: pull.state))
            .font(.callout)
            .foregroundStyle(statusIsFailure ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

        if case .pulling(_, let progress) = pull.state {
            progressView(progress?.display)
        }

        // 取消后的钉住提示：状态已落回 idle，但后台下载可能还在跑——给手动 Refresh，
        // 不承诺自动同步。复用 core 的同一句文案，不另造 key。
        // 事实本体在 store（simcodex R1 下沉）：sheet 关了重开，提示还在。
        if case .idle = pull.state, let abandoned = pull.lastAbandonedReference {
            HStack {
                Text(
                    ImagePullPresentation.statusLabel(
                        for: .cancellingForeground(reference: abandoned)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Refresh") {
                    Task { await model.images.refresh() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    /// 进度三档降级（`PullProgress.display` 已测）：分数 → 项计数 → 转圈。
    @ViewBuilder
    private func progressView(_ display: PullProgress.Display?) -> some View {
        switch display {
        case .fraction(let fraction):
            HStack {
                ProgressView(value: fraction)
                Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .monospacedDigit()
            }

        case .items(let count, let total):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("\(count) of \(total) items")
                    .font(.caption)
                    .monospacedDigit()
            }

        case .indeterminate, nil:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var statusIsFailure: Bool {
        if case .failed = pull.state { true } else { false }
    }

    private func startPull() {
        guard let reference = ImageRef(referenceText) else { return }
        pull.pull(reference)   // 起手清掉上一次的放弃提示（store 内，有测试）
    }
}
