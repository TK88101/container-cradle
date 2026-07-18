import ContainerCore

/// 一份写死的进程表快照。
///
/// 住在 test target（不是 `Sources/Testing/`）：跟 `FixedBackoff` 同理——
/// 只有测试需要它。`FakeContainerRuntimeClient` 之所以住在 `Sources/`，
/// 是因为 M0 的验收要求 app target 能构造它（菜单里渲染假容器）；进程表没有这个需求。
struct FakeProcessTable: ProcessTable {

    let records: [ProcessRecord]

    func snapshot() -> [ProcessRecord] { records }
}

extension ProcessRecord {

    /// 真机上此刻实际存在的那些进程（`ps -Ao pid,lstart,comm` + libproc spike 实测值）。
    ///
    /// **干扰项不是编出来的**：`machine-apiserver` 和 `containermanagerd` 就在这台 Mac 上跑着。
    /// 用「进程名含 apiserver」去匹配会**同时命中 machine-apiserver**——
    /// 那正是 `ApiserverProberTests` 里那条测试要钉死的坑。
    enum Real {

        static let apiserver = ProcessRecord(
            pid: 37850,
            executablePath: "/usr/local/bin/container-apiserver",
            startTime: 1_784_003_938_827_729
        )

        /// ★ 名字里也有 "apiserver"，路径完全不同。
        static let machineAPIServer = ProcessRecord(
            pid: 37860,
            executablePath: "/usr/local/libexec/container/plugins/machine-apiserver/bin/machine-apiserver",
            startTime: 1_784_003_938_900_000
        )

        /// macOS 自带的，跟 apple/container 毫无关系。
        static let containerManagerd = ProcessRecord(
            pid: 548,
            executablePath: "/usr/libexec/containermanagerd",
            startTime: 1_783_000_000_000_000
        )

        static let networkPlugin = ProcessRecord(
            pid: 37859,
            executablePath: "/usr/local/libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet",
            startTime: 1_784_003_938_850_000
        )

        /// apiserver **不在**时的进程表：其余进程仍然健在。
        static let withoutAPIServer: [ProcessRecord] = [
            containerManagerd, machineAPIServer, networkPlugin,
        ]

        /// apiserver 在跑时的完整进程表。
        static let withAPIServer: [ProcessRecord] = [
            containerManagerd, apiserver, machineAPIServer, networkPlugin,
        ]
    }
}
