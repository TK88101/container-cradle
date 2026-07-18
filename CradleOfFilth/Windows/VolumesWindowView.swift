import AppKit
import ContainerCore
import SwiftUI

/// Volume 管理窗口的常量。单实例 `Window`（不是 `WindowGroup(for:)`）：
/// volume 是全局资源，不按 ID 开多窗。
enum VolumesWindowScene {
    static let windowID = "volumes"
}

/// Volume 管理窗口（Day 10 M5）。**view 只绑定、只渲染**——
/// 双数显示（`VolumePresentation.sizeLabel`）、影响面文案（`deletionImpact`）、
/// 确认判据（`TypedConfirmation.canConfirm`）、fingerprint 复核（store 的 `verifying`）
/// 全部住 core，这里一行判断都没有。
struct VolumesWindowView: View {

    let model: AppModel

    private var store: VolumeListStore { model.volumes }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            refreshFailureBanner

            content
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle("Volumes")
        .task { await store.refresh() }
        .sheet(isPresented: confirmSheetShown) { confirmSheet }
        .alert("删除失败", isPresented: deleteFailedShown) {
            Button("好", role: .cancel) { store.cancelDeletion() }
        } message: {
            Text(deleteFailedReason)
        }
        .alert("卷已变化，删除已中止", isPresented: targetChangedShown) {
            Button("好", role: .cancel) { store.cancelDeletion() }
        } message: {
            Text("这个名字的卷在确认期间被外部改动过（可能被删除重建）。列表已刷新，请核对后重新发起删除。")
        }
    }

    // MARK: - 顶栏 / 状态条

    private var toolbar: some View {
        HStack {
            Text("\(store.displayedVolumes.count) 个 volume")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新列表（会重新统计真实占用）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var refreshFailureBanner: some View {
        if case .failed = store.state {
            Text("刷新失败——显示的是最后一次成功的列表")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if store.displayedVolumes.isEmpty {
            emptyState
        } else {
            List(store.displayedVolumes) { volume in
                volumeRow(volume)
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
            Text("没有 volume")
                .foregroundStyle(.secondary)
        }
        Spacer()
    }

    private func volumeRow(_ volume: Volume) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.system(.body, design: .monospaced))

                // ★ 永远双数（R7）：字符串由 core 生成并被测试钉死，view 不拼数字。
                Text(VolumePresentation.sizeLabel(used: volume.usedBytes, max: volume.sizeMaxBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("创建于 \(volume.creationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isBusy(with: volume) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(role: .destructive) {
                    store.beginDeletion(of: volume)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(deletionInFlight)
                .help("删除 volume（需要输入名字确认，数据不可恢复）")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 删除流程的绑定（状态住 store，这里只做 SwiftUI 形状转换）

    @ViewBuilder
    private var confirmSheet: some View {
        if case .confirming(let target) = store.deletionFlow {
            TypedConfirmationSheet(
                title: "删除 Volume",
                expectedName: target.name,
                destructiveLabel: "删除",
                details: VolumePresentation.deletionImpact(of: target),
                onConfirm: { typed in
                    Task { await store.confirmDeletion(typed: typed) }
                },
                onCancel: { store.cancelDeletion() }
            )
        }
    }

    private var confirmSheetShown: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = store.deletionFlow { true } else { false }
            },
            set: { shown in
                if !shown { store.cancelDeletion() }
            }
        )
    }

    private var deleteFailedShown: Binding<Bool> {
        Binding(
            get: {
                if case .failed = store.deletionFlow { true } else { false }
            },
            set: { shown in
                if !shown { store.cancelDeletion() }
            }
        )
    }

    private var deleteFailedReason: String {
        if case .failed(_, let reason) = store.deletionFlow { reason } else { "" }
    }

    private var targetChangedShown: Binding<Bool> {
        Binding(
            get: {
                if case .targetChanged = store.deletionFlow { true } else { false }
            },
            set: { shown in
                if !shown { store.cancelDeletion() }
            }
        )
    }

    private var deletionInFlight: Bool {
        switch store.deletionFlow {
        case .verifying, .deleting:
            true
        case .idle, .confirming, .failed, .targetChanged:
            false
        }
    }

    private func isBusy(with volume: Volume) -> Bool {
        switch store.deletionFlow {
        case .verifying(let target), .deleting(let target):
            target.id == volume.id
        case .idle, .confirming, .failed, .targetChanged:
            false
        }
    }
}
