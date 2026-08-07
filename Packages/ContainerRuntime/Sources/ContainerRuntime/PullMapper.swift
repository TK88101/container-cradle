import ContainerCore
import TerminalProgress

/// 上游 `[ProgressUpdateEvent]` → domain `PullProgress`（§3.3 / T5）。
///
/// **D1 白名单文件**：唯一在 `ContainerRuntime` 里 import `TerminalProgress` 的地方。上游进度类型
/// 到这里为止，`PullProgress` 之后只剩 domain。**无 reveal**（镜像进度无密钥面）——进 D1 白名单，但
/// 不进 D2 明文预算。
///
/// ## 为什么是「跨批折叠」而不是一次性纯函数
///
/// 上游进度**分批投递**：pull 的每一次 XPC 回调给一个 `[ProgressUpdateEvent]` 批次，而计数分两族——
/// `set*` 是全量快照、`add*` 是增量。**漏掉「跨批累积 add*」就重演 T2b 的「字节假 0」**
/// （spike 初版只数 `set*`，把实际走增量族的字节流读成 0）。所以状态必须跨批 fold：streaming 时把上一次
/// 的 `PullProgress` 喂回 `folding`。`PullProgress` 本身既是「当前累积状态」又是「对外快照」——每一次
/// 折叠出的都是那一刻的合法快照（这正是流式进度想要的），无需再造一个孪生累积器类型。
///
/// 累积语义**逐位镜像上游** `ProgressBar+Add.swift`：`set→=`（全量覆盖）、`add→+=`（增量累加），
/// total 的 add 用 `(当前 ?? 0) + delta`。上游怎么算，这里就怎么算——档位才对得上进度条。
/// 值语义：`folding` 不改入参、返回新副本（全局 §7 不可变）。
enum PullMapper {

    /// 累积起点：什么都还没报。计数保持 `nil`（「从未报告」）而非 0——档位只由「总量有没有值」决定
    /// （见 `PullProgress.display`），当前值缺失时 UI 用 `?? 0` 兜底显示。
    static let initial = PullProgress(phase: "", items: nil, totalItems: nil, bytes: nil, totalBytes: nil)

    /// 把一批事件折叠进 `current`，返回**新**快照（不改入参）。跨批场景把上一次的结果喂回来。
    static func folding(_ current: PullProgress, with events: [ProgressUpdateEvent]) -> PullProgress {
        var phase = current.phase
        var items = current.items
        var totalItems = current.totalItems
        var bytes = current.bytes          // 上游叫 size，翻到 domain 词汇 bytes——这正是 mapper 的职责
        var totalBytes = current.totalBytes

        for event in events {
            switch event {
            case .setDescription(let description):
                // phase = 给人看的活动标签。pull 发的是 "Fetching image" / "Unpacking image"
                // （已核 Utility.swift）——正是这个字段。最后一个覆盖。
                phase = description

            case .addItems(let delta):
                items = (items ?? 0) + delta
            case .setItems(let value):
                items = value
            case .addTotalItems(let delta):
                totalItems = (totalItems ?? 0) + delta
            case .setTotalItems(let value):
                totalItems = value

            case .addSize(let delta):
                bytes = (bytes ?? 0) + delta
            case .setSize(let value):
                bytes = value
            case .addTotalSize(let delta):
                totalBytes = (totalBytes ?? 0) + delta
            case .setTotalSize(let value):
                totalBytes = value

            case .setSubDescription, .setItemsName,
                .addTasks, .setTasks, .addTotalTasks, .setTotalTasks,
                .custom:
                // `PullProgress` 刻意不建模：task 计数（pull 不用它）、subDescription/itemsName
                // （无对应 domain 字段）、custom（客户端私有）。**不写 `default:`**——上游哪天加
                // 事件 case，编译器强制在这里重新做一次决定（爆炸半径可见，R-FLAGS）。
                break
            }
        }

        return PullProgress(phase: phase, items: items, totalItems: totalItems, bytes: bytes, totalBytes: totalBytes)
    }

    /// 一次性把完整事件列表折叠成快照（从 `initial` 起）。跨批场景用 `folding` 逐批喂。
    static func progress(from events: [ProgressUpdateEvent]) -> PullProgress {
        folding(initial, with: events)
    }
}
