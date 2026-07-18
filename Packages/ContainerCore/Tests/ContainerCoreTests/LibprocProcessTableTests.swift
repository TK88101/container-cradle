import Darwin
import Foundation
import Testing

@testable import ContainerCore

/// libproc 那一层本来被当成「覆盖率豁免项」——**而它藏了一个 P1**（codex review 抓到的）：
/// `proc_listallpids` 的返回值被当成字节数除以 4，于是**只扫了 1/4 的进程**。
///
/// 那个 bug 在真机上照样「能跑」：apiserver 的 pid 恰好排在前 1/4 里。
/// 它要等到机器跑久了、新进程把 apiserver 挤出前 1/4 才会突然发作——
/// 而发作的样子是 supervisor 在运行时活得好好的时候报「运行时挂了」，然后反复空 reconcile。
///
/// **教训：「不好测」不等于「不用测」。** 该豁免的是「拿不到确定性输入的部分」，
/// 不是「懒得想怎么测的部分」。这个文件就是那个反例。
@Suite("LibprocProcessTable")
struct LibprocProcessTableTests {

    private let table = LibprocProcessTable()

    /// ★ **金丝雀：低 pid 的老进程。**
    ///
    /// 内核给的 pid 列表是**降序**的。一旦发生截断，活下来的只有最新的那几百个 pid——
    /// **开机初期启动的老进程会集体消失**。而 apiserver 恰恰是「开机时起来、之后一直跑」
    /// 的那一类：机器跑久了，它必然被新进程挤到列表后半段。
    ///
    /// 实测本机最小的可完整读取 pid 是 457（`loginwindow`）；截断版本能看到的最小 pid
    /// 是五位数。所以「看得见 pid < 1000 的进程」= 「我们真的扫到了列表末尾」。
    ///
    /// （**不能拿 launchd（pid 1）当金丝雀**——它的 `proc_pidinfo` 被 SIP 挡着读不到，
    /// 会走「读不到就跳过」那条**正确**路径。第一版就是这么写错的：
    /// 把权限拒绝误当成了截断。）
    @Test("能看到低 pid 的老进程 —— 说明扫到了列表末尾，没被截断")
    func seesEarlySystemProcesses() {
        #expect(table.snapshot().contains { $0.pid < 1_000 })
    }

    /// 自己也得在里面。看不到自己，说明 libproc 的调用本身就是坏的。
    @Test("能看到当前测试进程自己")
    func seesItself() {
        let me = ProcessInfo.processInfo.processIdentifier

        #expect(table.snapshot().contains { $0.pid == me })
    }

    /// 截断的另一个信号：拿到的进程数远少于内核报的总数。
    ///
    /// 不能要求**完全相等**——受 SIP 保护的系统进程读不到 `proc_pidinfo`（那是常态，
    /// 我们的策略是跳过而不是报错，实测能完整读到约 64%）。
    /// 但漏掉的绝不该是绝大多数：那个 P1 让它只剩 20%。
    @Test("枚举到的进程数与内核报的总数在同一量级（不是只剩 1/5）")
    func doesNotTruncate() {
        let reported = proc_listallpids(nil, 0)
        let seen = table.snapshot().count

        #expect(reported > 0)
        // 正常约 64%，bug 下约 20%。1/3 是个两边都留足余量的门槛——
        // 既不会在别的机器上假红，也一定抓得住那个 bug。
        #expect(seen > Int(reported) / 3)
    }

    @Test("每条记录都是完整的（pid / 路径 / 启动时刻都拿到了）")
    func recordsAreComplete() {
        for record in table.snapshot().prefix(20) {
            #expect(record.pid > 0)
            #expect(!record.executablePath.isEmpty)
            #expect(record.startTime > 0)
        }
    }
}
