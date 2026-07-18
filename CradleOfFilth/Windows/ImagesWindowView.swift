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

            Button {
                Task { await store.refresh() }
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

    /// D-C fail-closed 的可见形态：非权威过滤 → 明说为什么删不了，不是按钮悄悄变灰。
    @ViewBuilder
    private var deletionDisabledBanner: some View {
        if !store.deletionEnabled {
            Text("Cannot confirm the system-image filter (config failed to load); deletion is disabled")
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
