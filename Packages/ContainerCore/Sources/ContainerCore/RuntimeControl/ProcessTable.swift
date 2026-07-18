/// 进程表里的一条：**判断运行时死活所需的全部信息**，一个字段都不多。
///
/// 刻意不带 command line / uid / 父进程：它们全都会诱使人写出「更聪明」的匹配规则
/// （按参数猜、按用户猜），而唯一正确的规则是**完整可执行路径全等**（见 `ApiserverProber`）。
/// 字段不存在，规则就写不歪。
public struct ProcessRecord: Sendable, Equatable {

    public let pid: Int32

    /// **完整**可执行路径（libproc `proc_pidpath`）。不是进程名——
    /// 进程名会把 `machine-apiserver` 和 `container-apiserver` 混为一谈（实测同机共存）。
    public let executablePath: String

    /// 进程启动时刻，微秒（`proc_bsdinfo.pbi_start_tvsec` × 1e6 + `pbi_start_tvusec`）。
    ///
    /// 它是 `RuntimeGeneration` 的第二个分量，存在的唯一理由是**pid 会被复用**：
    /// apiserver 挂掉后系统可以把同一个 pid 分给新的 apiserver，只比 pid 就漏判换代。
    public let startTime: UInt64

    public init(pid: Int32, executablePath: String, startTime: UInt64) {
        self.pid = pid
        self.executablePath = executablePath
        self.startTime = startTime
    }
}

/// 读一次进程表。
///
/// 抽成 protocol 不是为了「将来换实现」——是为了让 `ApiserverProber` 的**匹配规则**
/// （唯一有判断力的那部分）能被单测钉死。真实实现 `LibprocProcessTable` 是覆盖率的
/// 明确豁免项（PLAN「80% 覆盖率怎么达到」），代价是它必须**薄到没有可出错的地方**。
public protocol ProcessTable: Sendable {

    /// 当前全部进程。**读不到的进程直接跳过，不抛错**——
    /// 权限不足、进程刚退出都会让单条读取失败，那是常态而非异常；
    /// 为一条读不到的无关进程抛错，会让整次探测失败，supervisor 当场变瞎。
    func snapshot() -> [ProcessRecord]
}
