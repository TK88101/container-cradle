/// 「apiserver 现在还在不在？是不是换了一条命？」
///
/// **这是 supervisor 判断运行时死活的唯一权威来源**（R14）。诱惑是拿 XPC 错误当依据——
/// 不行：apiserver 挂掉时 XPC 报的是大杂烩的 `.internalError`，跟「launchd 还没 on-demand
/// 拉起它」「Mach service 名字对不上」「瞬时抖动」长得一模一样，没有专门的 unavailable 分类。
/// 靠嗅 cause 字符串（`"XPC connection error"`）更脆：上游改一个字就失效，**且无声**。
///
/// 进程表不会骗人。
public protocol RuntimeProber: Sendable {

    func probe() async -> ProbeResult
}

/// 在进程表里找 apiserver。**全部判断力集中在这里，而这里是纯函数。**
///
/// libproc 那一侧（`LibprocProcessTable`）一个 `if` 都没有，所以「探测判错」这件事
/// 只可能发生在下面这十几行里——而它们 100% 被单测覆盖。
public struct ApiserverProber: RuntimeProber {

    /// apiserver 的安装位置（实测：`launchctl list` 里 `com.apple.container.apiserver` → pid 37850，
    /// 其可执行文件正是这个路径）。
    public static let defaultExecutablePath = "/usr/local/bin/container-apiserver"

    private let table: any ProcessTable
    private let executablePath: String

    public init(
        table: any ProcessTable = LibprocProcessTable(),
        executablePath: String = ApiserverProber.defaultExecutablePath
    ) {
        self.table = table
        self.executablePath = executablePath
    }

    /// ## 匹配必须是**完整路径全等**，不能是「名字里含 apiserver」
    ///
    /// 同一台 Mac 上此刻还跑着
    /// `/usr/local/libexec/container/plugins/machine-apiserver/bin/machine-apiserver`（实测）。
    /// 子串匹配会把它也认成运行时，后果是两个方向的灾难：
    ///
    /// - apiserver 真挂了时，prober 仍报 running（拿的是 machine-apiserver 的令牌）
    ///   → `.runtimeDown` **永远不会发生** → 核心场景下 reconcile 永远不触发；
    /// - 两个都在时，令牌取谁不确定 → 令牌抖动 → **反复误 reconcile**。
    ///
    /// ## 多个命中时取 `startTime` 最早的
    ///
    /// 规则**取哪个不重要，确定性才重要**。若取「进程表里的第一个」，而顺序由内核决定、
    /// 两次调用可能不同 → 令牌在两个 pid 之间来回跳 → reducer 每次都看到「换代了」→
    /// **无限 reconcile**。取最早的：它是主实例，后来的（fork 中、旧实例没退干净）都排它后面。
    public func probe() -> ProbeResult {
        let matches = table.snapshot().filter { $0.executablePath == executablePath }

        guard let oldest = matches.min(by: { $0.startTime < $1.startTime }) else {
            return .down
        }

        return .running(RuntimeGeneration(pid: oldest.pid, startTime: oldest.startTime))
    }
}
