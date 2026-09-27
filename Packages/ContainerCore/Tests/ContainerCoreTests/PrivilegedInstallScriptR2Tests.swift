import Foundation
import Testing

@testable import ContainerCore

/// 评审 R2（Plan 附录 B）落到 root 脚本上的修复，逐条一个离线测试。重定位手法同 `PrivilegedInstallScriptHardeningTests`。
@Suite("root 脚本 R2：状态目录、装后失败关闭、信号、输出、时钟、前导零")
struct PrivilegedInstallScriptR2Tests {

    typealias H = PrivilegedInstallScriptHardeningTests

    static func shell(_ command: String, _ args: String...) throws -> ProcessResult {
        try PrivilegedInstallScriptTests.shell(command, args)
    }

    // MARK: - C：状态目录必须是本身份的 0755 真目录（生产 = root，父链 root-only）

    @Test("状态目录是符号链接 / 普通文件 → busy（rundir-not-directory），不跟随、不创建")
    func runDirMustBeRealDirectory() throws {
        let box = try H.Sandbox()
        let pkg = try box.fakePackage()
        let elsewhere = box.dir.path("elsewhere")
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: box.run)

        try FileManager.default.createSymbolicLink(atPath: box.run, withDestinationPath: elsewhere)
        let link = try box.run(H.args(pkg: pkg))
        #expect(link.stdout == "COF_DETAIL=rundir-not-directory\nCOF_RESULT=busy\n", "\(link.stdout)\(link.stderr)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)

        try FileManager.default.removeItem(atPath: box.run)
        try Data().write(to: URL(fileURLWithPath: box.run))
        let file = try box.run(H.args(pkg: pkg))
        #expect(file.stdout == "COF_DETAIL=rundir-not-directory\nCOF_RESULT=busy\n", "\(file.stdout)\(file.stderr)")
    }

    @Test("状态目录 group / other 可写（0775 / 0757）或不是 0755 → busy（rundir-unsafe）", arguments: [0o775, 0o757, 0o700])
    func runDirMustBe0755(mode: Int) throws {
        let box = try H.Sandbox()
        let pkg = try box.fakePackage()
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: box.run)
        let result = try box.run(H.args(pkg: pkg))
        #expect(result.stdout == "COF_DETAIL=rundir-unsafe=\(getuid()) \(String(mode, radix: 8))\nCOF_RESULT=busy\n",
                "\(result.stdout)\(result.stderr)")
        #expect(try box.runEntries().isEmpty)   // 一个文件都没建（锁也没有）
    }

    @Test("状态目录不存在 → 以 0755 新建，照常往下走")
    func runDirIsCreated() throws {
        let box = try H.Sandbox()
        let pkg = try box.fakePackage()
        try FileManager.default.removeItem(atPath: box.run)
        let result = try box.run(H.args(pkg: pkg))
        #expect(result.stdout.hasSuffix("COF_RESULT=digest-mismatch\n"), "\(result.stdout)\(result.stderr)")
        let attributes = try FileManager.default.attributesOfItem(atPath: box.run)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)
        #expect(try box.runEntries() == ["cof-runtime-update.lock"])
    }

    // MARK: - I：阻塞者名字不许伪造协议行

    @Test("report_busy 不解释反斜杠转义：lsof 转义的 \\n、\\c 原样输出，一名一行")
    func reportBusyDoesNotInterpretEscapes() throws {
        let dir = try TempDir()
        try #"/tmp/y\nCOF_DETAIL=installer-exit=0\nCOF_RESULT=installed"#.appending("\n/tmp/a\\cTRUNC\n")
            .write(toFile: dir.path("busy"), atomically: true, encoding: .utf8)
        let harness = """
        set -eu
        WORK="$1"
        \(PrivilegedInstallScript.busyFunctions)
        report_busy
        """
        let result = try Self.shell(#"exec /bin/sh -c "$1" x "$2""#, harness, dir.url.path)
        #expect(result.stdout == #"COF_BUSY=/tmp/y\nCOF_DETAIL=installer-exit=0\nCOF_RESULT=installed"# + "\n" + #"COF_BUSY=/tmp/a\cTRUNC"# + "\n")
    }

    // MARK: - H：时钟回拨 = 超时（失败关闭）

    @Test("等待期间时钟往回走 → 当轮就 stop-timeout，不会等回拨的那么久")
    func clockRollbackTimesOut() throws {
        let dir = try TempDir()
        let section = try H.replacing(PrivilegedInstallScript.waitSection, [
            (old: "/bin/date +%s", new: "clock_now", count: 2),
            (old: "/bin/sleep 1", new: ":", count: 1),
        ])
        let harness = """
        set -eu
        WORK="$1"; RUNDIR="$1"; NONCE=N; WAIT=300; STATE=
        : > "$WORK/calls"
        clock_now() { if [ -s "$WORK/started" ]; then echo 1790000000; else echo 1790003600 > "$WORK/started"; echo 1790003600; fi; }
        list_busy() {
            echo x >> "$WORK/calls"
            if [ "$(/usr/bin/wc -l < "$WORK/calls")" -gt 5 ]; then echo LOOPING; exit 3; fi
            echo /usr/local/bin/container > "$WORK/busy"
        }
        report_busy() { printf 'COF_BUSY=%s\\n' "$(/bin/cat "$WORK/busy")"; }
        write_state() { :; }
        finish() { printf 'COF_RESULT=%s\\n' "$1"; exit 0; }
        \(section)
        """
        let result = try Self.shell(#"exec /bin/sh -c "$1" x "$2""#, harness, dir.url.path)
        #expect(result.stdout == "COF_BUSY=/usr/local/bin/container\nCOF_RESULT=stop-timeout\n", "\(result.stdout)\(result.stderr)")
        #expect(try String(contentsOfFile: dir.path("calls"), encoding: .utf8) == "x\n")
    }

    // MARK: - B：装后复查与装前同构、失败关闭

    /// installSegment 单独跑：installer 换成桩，list_busy 按参数打桩。
    static func runInstallSegment(listBusyRC: Int, busy: String) throws -> String {
        let dir = try TempDir()
        let harness = """
        set -eu
        WORK="$1"; BUSY="$2"; RC="$3"; STATE=; INSTALLER=/usr/bin/true
        finish() { printf 'COF_RESULT=%s\\n' "$1"; exit 0; }
        list_busy() { printf '%s' "$BUSY" > "$WORK/busy"; return "$RC"; }
        report_busy() { while IFS= read -r b; do printf 'COF_BUSY=%s\\n' "$b"; done < "$WORK/busy"; }
        \(PrivilegedInstallScript.installSegment)
        """
        return try Self.shell(#"exec /bin/sh -c "$1" x "$2" "$3" "$4""#, harness, dir.url.path, busy, String(listBusyRC)).stdout
    }

    @Test("装后：干净 → installed；有人映射本包文件 → raced；lsof 看不清 → raced（阻塞者 lsof-failed）")
    func postInstallCheckFailsClosed() throws {
        #expect(try Self.runInstallSegment(listBusyRC: 0, busy: "") == "COF_RESULT=installed\n")
        #expect(try Self.runInstallSegment(listBusyRC: 0, busy: "/usr/local/bin/container\n")
            == "COF_BUSY=/usr/local/bin/container\nCOF_RESULT=raced\n")
        #expect(try Self.runInstallSegment(listBusyRC: 1, busy: "lsof-failed\n")
            == "COF_BUSY=lsof-failed\nCOF_RESULT=raced\n")
    }

    // MARK: - J：installer 起到结束一直忽略可终止信号；cleanup 不改退出码

    /// 真 preamble（含 EXIT trap / cleanup）+ 打桩 + installSegment；`signal` 在 `after` 秒时发给 sh 本身。
    static func runWithSignal(_ signal: String, after: Double, installerSleep: Double, listBusySleep: Double) throws -> (out: String, marker: Bool, state: String) {
        let dir = try TempDir()
        let work = dir.path("work")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try Data("pkg".utf8).write(to: URL(fileURLWithPath: "\(work)/update.pkg"))
        let installer = dir.path("installer")
        try "#!/bin/sh\n/bin/sleep \(installerSleep)\nif [ -f \"$2\" ]; then echo ok > \"$MARK\"; fi\nexit 0\n"
            .write(toFile: installer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer)
        let harness = """
        \(PrivilegedInstallScript.preamble)
        RUNDIR="$1"; WORK="$2"; INSTALLER="$3"; STATE="$1/state"
        list_busy() { /bin/sleep \(listBusySleep); : > "$WORK/busy"; }
        report_busy() { :; }
        \(PrivilegedInstallScript.installSegment)
        """
        let result = try Self.shell(
            #"MARK="$5" /bin/sh -c "$1" x "$2" "$3" "$4" & p=$!; /bin/sleep \#(after); kill -\#(signal) $p; wait $p; echo "rc=$?""#,
            harness, dir.url.path, work, installer, dir.path("marker")
        )
        let state = (try? String(contentsOfFile: dir.path("state"), encoding: .utf8)) ?? ""
        return (result.stdout, FileManager.default.fileExists(atPath: dir.path("marker")), state)
    }

    @Test("装后复查期间收到 TERM → 仍是 installed（不被改写成 interrupted），退出 0")
    func signalAfterInstallerIsIgnored() throws {
        let run = try Self.runWithSignal("TERM", after: 0.6, installerSleep: 0, listBusySleep: 1.5)
        #expect(run.out == "COF_RESULT=installed\nrc=0\n", "\(run.out)")
        #expect(run.state == "phase=done\nresult=installed\n")
    }

    @Test("installer 期间收到 USR1 / ALRM / QUIT → 不跑 cleanup（installer 读得到包），结果照常", arguments: ["USR1", "ALRM", "QUIT"])
    func otherSignalsDuringInstallerAreIgnored(signal: String) throws {
        let run = try Self.runWithSignal(signal, after: 0.5, installerSleep: 1.5, listBusySleep: 0)
        #expect(run.marker, "installer 醒来时包已被删（cleanup 提前跑了）")
        #expect(run.out == "COF_RESULT=installed\nrc=0\n", "\(run.out)")
    }

    @Test("finish 之后 cleanup 删不掉工作目录 → 退出码仍是 0（结果行不被 osascript 丢弃）")
    func cleanupFailureDoesNotFlipExitCode() throws {
        let dir = try TempDir()
        let locked = dir.path("locked")
        try FileManager.default.createDirectory(atPath: "\(locked)/w", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let harness = """
        \(PrivilegedInstallScript.preamble)
        WORK="$1/w"
        finish installed
        """
        let result = try Self.shell(#"/bin/sh -c "$1" x "$2"; echo "rc=$?""#, harness, locked)
        #expect(result.stdout == "COF_RESULT=installed\nrc=0\n", "\(result.stdout)\(result.stderr)")
    }
}
