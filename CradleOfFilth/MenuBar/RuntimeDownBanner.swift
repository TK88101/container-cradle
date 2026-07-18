import ContainerCore
import SwiftUI

/// 运行时不可用时的横幅。**这是本 App 最该做好的一块 UI。**
///
/// apple/container 没有 restart policy：运行时一停，容器全停；运行时再起来，容器不会自己回来。
/// 这个横幅就是用户看见那个「洞」的时刻——它必须说清发生了什么，
/// 而不是甩一个 "Error" 让人去猜。
struct RuntimeDownBanner: View {

    let error: RuntimeError

    /// 下方是否还有可看的旧数据。有的话文案要点明「下面是旧的」，
    /// 否则用户会把陈旧列表当成当前状态。
    let hasStaleData: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private var icon: String {
        switch error {
        case .runtimeUnavailable: "bolt.slash"
        case .containerNotFound: "questionmark.circle"
        case .mountSourceUnavailable: "externaldrive.badge.questionmark"
        case .operationFailed: "exclamationmark.triangle"
        }
    }

    /// `Text(title)` 是 verbatim（title 是 `String` 变量，不是字面 key）——所以标题
    /// 必须在这里就地本地化，不能指望 SwiftUI 的 LocalizedStringKey 自动查表（codex #6）。
    private var title: String {
        switch error {
        case .runtimeUnavailable: String(localized: "The container runtime is not running")
        case .containerNotFound: String(localized: "Container not found")
        case .mountSourceUnavailable: String(localized: "Mount source not ready yet")
        case .operationFailed: String(localized: "Operation failed")
        }
    }

    /// 文案要让用户知道**下一步该做什么**，而不是复述错误码。
    ///
    /// `.mountSourceUnavailable` 尤其如此：它的正解是「去把那块盘插上」，
    /// 而一句笼统的「启动失败」只会把人赶去翻日志——翻到的还是同一句话。
    ///
    /// `.operationFailed(reason)` 的 reason 是 runtime 层英文诊断串，**原样透传不翻译**
    /// （Day 14 §1：技术详情保持可搜索）。
    private var detail: String {
        switch error {
        case .runtimeUnavailable:
            hasStaleData
                ? String(localized: "Below is the state before the runtime stopped, not the current state.")
                : String(localized: "Containers will appear here after you start the apple/container runtime.")
        case .containerNotFound(let id):
            String(localized: "Container \(id.rawValue) not found. It may have been deleted.")
        case .mountSourceUnavailable(let path):
            String(localized: "\(path) does not exist on the host yet. An external disk or network volume may not be attached — it will retry automatically once mounted.")
        case .operationFailed(let reason):
            reason
        }
    }
}
