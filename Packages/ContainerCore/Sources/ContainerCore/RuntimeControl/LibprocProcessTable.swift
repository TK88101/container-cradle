import Darwin

/// 真实进程表，走 libproc。**覆盖率的明确豁免项**（PLAN「80% 覆盖率怎么达到」）——
/// 它没法在单测里驱动（要真进程），所以它的正当性只能来自一件事：**薄到没有可出错的地方**。
///
/// 于是这里**一个判断都不做**：不匹配、不过滤、不排序、不解释。
/// 「哪个进程是 apiserver」的全部判断力在 `ApiserverProber` 里，那儿是纯函数，100% 可测。
/// 每往这个文件里加一行 `if`，就有一行代码永远没有测试守着。
///
/// ## 为什么可以直接用 Swift，不需要 C shim
///
/// spike 实测：`proc_listallpids` / `proc_pidpath` / `proc_pidinfo` 在 `import Darwin` 下
/// 直接可见。唯一导不进来的是 `PROC_PIDPATHINFO_MAXSIZE`——它是依赖 `MAXPATHLEN` 的宏，
/// Swift 报 "macro unavailable: structure not supported"。所以下面硬编码 `4 * MAXPATHLEN`。
///
/// ## 成本
///
/// 每次快照对每个进程两次系统调用（path + bsdinfo）。实测本机 238 个进程，整轮耗时远低于
/// 1 ms，而探测间隔是秒级——**零 XPC、零网络**，这正是 supervisor 能在「全量轮询完全停掉」
/// 时依然灵敏的原因（PLAN「自适应 cadence」）。
public struct LibprocProcessTable: ProcessTable {

    /// `PROC_PIDPATHINFO_MAXSIZE` 的值（`4 * MAXPATHLEN`，MAXPATHLEN = 1024）。
    /// Swift 导不进那个宏（"macro unavailable: structure not supported"），只能写死。
    private static let maxPathSize = 4 * 1024

    public init() {}

    public func snapshot() -> [ProcessRecord] {
        allPIDs().compactMap(record(for:))
    }

    /// 全部 pid。
    ///
    /// ## ★ 刻意**不解读返回值的单位**（codex review 抓到的 P1，实测确认）
    ///
    /// `proc_listallpids` 的返回值到底是「pid 个数」还是「字节数」，文档说法与实际行为
    /// **对不上**。实测（macOS 26.5）：返回 `970`，而缓冲区里真实非零 pid 有 **969** 个——
    /// 它是**个数**。按「字节数」解读（`ret / sizeof(pid_t)`）只会扫到 242 个，
    /// **漏掉 727 个进程（75%）**。
    ///
    /// 而 pid 列表是**降序**的：apiserver 会随着机器运行被越来越多的新进程挤出前 1/4，
    /// 于是 probe 在运行时活得好好的时候报 `.down` → 下一轮又看到 running（同一代）→
    /// 走 `.runtimeDown → running` 边沿 → **反复空 reconcile**，菜单栏还会疯狂闪
    /// 「运行时挂了」。**编译绿、测试绿，看不出任何异常。**
    ///
    /// 所以这里不押注任何一种解读：缓冲区是**零初始化**的，直接过滤全部非零项。
    /// 两种解读下都正确，将来 OS 改了单位也不会错。（`LibprocProcessTableTests` 用
    /// launchd 当金丝雀钉死这一条——它是降序列表的**最后一个**，一截断就消失。）
    ///
    /// 缓冲区按内核报的数量**翻倍**申请：两次调用之间进程数会涨，而缓冲区不够时
    /// 内核**静默截断**（不报错）。
    private func allPIDs() -> [pid_t] {
        let reported = proc_listallpids(nil, 0)
        guard reported > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(reported) * 2)
        guard proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)) > 0 else {
            return []
        }

        return pids.filter { $0 > 0 }
    }

    /// 单个进程。**读不到就返回 nil，不抛错**：进程可能在两次系统调用之间退出了，
    /// 或者我们没权限读它（系统进程）。那是常态。为一条读不到的无关进程让整次探测失败，
    /// supervisor 当场变瞎——而它瞎掉的时候，看起来和「一切正常」一模一样。
    private func record(for pid: pid_t) -> ProcessRecord? {
        var pathBuffer = [CChar](repeating: 0, count: Self.maxPathSize)
        guard proc_pidpath(pid, &pathBuffer, UInt32(Self.maxPathSize)) > 0 else { return nil }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        return ProcessRecord(
            pid: pid,
            executablePath: String(cString: pathBuffer),
            startTime: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        )
    }
}
