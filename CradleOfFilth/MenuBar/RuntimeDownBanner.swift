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

    private var title: String {
        switch error {
        case .runtimeUnavailable: "容器运行时没在运行"
        case .containerNotFound: "容器不存在"
        case .mountSourceUnavailable: "挂载源还没就绪"
        case .operationFailed: "操作失败"
        }
    }

    /// 文案要让用户知道**下一步该做什么**，而不是复述错误码。
    ///
    /// `.mountSourceUnavailable` 尤其如此：它的正解是「去把那块盘插上」，
    /// 而一句笼统的「启动失败」只会把人赶去翻日志——翻到的还是同一句话。
    private var detail: String {
        switch error {
        case .runtimeUnavailable:
            hasStaleData
                ? "下面是运行时停止前的状态，不是当前状态。"
                : "启动 apple/container 运行时后，这里会显示容器。"
        case .containerNotFound(let id):
            "找不到容器 \(id.rawValue)。它可能已被删除。"
        case .mountSourceUnavailable(let path):
            "宿主上的 \(path) 还不存在。外置盘或网络卷可能还没挂上——挂上之后会自动重试。"
        case .operationFailed(let reason):
            reason
        }
    }
}
