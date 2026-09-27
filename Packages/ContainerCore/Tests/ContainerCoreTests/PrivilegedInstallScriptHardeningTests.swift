import Foundation
import Testing

@testable import ContainerCore

/// 安全评审 R1（Day 22 Phase 3，Plan 附录 B）的 root 侧加固，逐条一个离线测试。
///
/// ## 「重定位」不是测试缝
///
/// root 脚本里的状态目录（`/private/var/db/cof-runtime-update`）与 `/private/var/tmp` 是常量，argv 碰不到它们（Plan §5.3：没有测试专用的可替换路径）。
/// 这里在**测试进程里**把常量文本逐字换成临时目录，再以普通用户身份跑**生产同一份**脚本的 install 模式。
/// 换之前先断言原文恰好出现 N 次：脚本改了形状，测试会红，而不是悄悄去碰真的系统目录。
@Suite("root 脚本加固（安全评审 R1）")
struct PrivilegedInstallScriptHardeningTests {

    static let validNonce = PrivilegedInstallScriptTests.validNonce
    static let wrongDigest = String(repeating: "b", count: 64)
    static var uid: String { String(getuid()) }

    /// 生产脚本的参数表，只在这一处拼——参数个数变了只改这里（下面「合法参数不被拒」那条守着它没拼错）。
    static func args(
        mode: String = "install", pkg: String, sha: String = wrongDigest, owner: String = uid,
        nonce: String = validNonce, wait: String = "1", target: String = "1.4.1"
    ) -> [String] {
        [mode, pkg, sha, owner, nonce, wait, target]
    }

    /// 把脚本里的常量逐字替换；每条都先断言原文恰好出现 `count` 次。
    static func replacing(_ script: String, _ edits: [(old: String, new: String, count: Int)]) throws -> String {
        var result = script
        for edit in edits {
            let found = result.components(separatedBy: edit.old).count - 1
            try #require(found == edit.count, "「\(edit.old)」应出现 \(edit.count) 次，实际 \(found) 次——脚本形状变了，先改测试")
            result = result.replacingOccurrences(of: edit.old, with: edit.new)
        }
        return result
    }

    /// 一个临时的 `run/`（代替状态目录，显式 0755——脚本会验它的属主与 mode）与 `tmp/`（代替 /private/var/tmp）。
    final class Sandbox {
        let dir: TempDir
        var run: String { dir.path("run") }
        var tmp: String { dir.path("tmp") }

        init() throws {
            dir = try TempDir()
            for sub in ["run", "tmp"] {
                try FileManager.default.createDirectory(atPath: dir.path(sub), withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(sub))
            }
        }

        func script(_ extra: [(old: String, new: String, count: Int)] = []) throws -> String {
            try PrivilegedInstallScriptHardeningTests.replacing(PrivilegedInstallScript.rootScript, [
                (old: "RUNDIR=\(PrivilegedInstallScript.stateDirectory)\n", new: "RUNDIR=\(run)\n", count: 1),
                (old: "WORKROOT=/private/var/tmp\n", new: "WORKROOT=\(tmp)\n", count: 1),
            ] + extra)
        }

        func run(_ args: [String], extra: [(old: String, new: String, count: Int)] = []) throws -> ProcessResult {
            try PrivilegedInstallScriptTests.runScript(try script(extra), args)
        }

        func runEntries() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: run).sorted()
        }

        /// 一个属于自己的、digest 与 `wrongDigest` 对不上的假包。
        func fakePackage() throws -> String {
            let path = dir.path("fake.pkg")
            try Data("not a package".utf8).write(to: URL(fileURLWithPath: path))
            return path
        }
    }

    // MARK: - 参数表本身没拼错（否则下面每条 bad-args 都会「恰好通过」）

    @Test("合法参数不被拒：包不存在 → bad-source，而不是 bad-args")
    func validArgumentsPassValidation() throws {
        let result = try PrivilegedInstallScriptTests.runScript(Self.args(mode: "verify-only", pkg: "/nonexistent/u.pkg"))
        #expect(result.stdout.hasSuffix("COF_RESULT=bad-source\n"), "\(result.stdout)")
    }

    // MARK: - H1 第三层：ready 之前根本不存在状态文件

    @Test("install 模式在 ready 之前失败（digest / 签名）→ 状态目录里只有锁文件，没有状态文件")
    func noStateFileBeforeReady() throws {
        let box = try Sandbox()
        let pkg = try box.fakePackage()

        let wrong = try box.run(Self.args(pkg: pkg))
        #expect(wrong.stdout.hasSuffix("COF_RESULT=digest-mismatch\n"), "\(wrong.stdout)\(wrong.stderr)")
        #expect(try box.runEntries() == ["cof-runtime-update.lock"])

        let actual = try PrivilegedInstallScriptTests.shell(#"/sbin/sha256 -q "$1""#, pkg).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let unsigned = try box.run(Self.args(pkg: pkg, sha: actual))
        #expect(unsigned.stdout.hasSuffix("COF_RESULT=signature-invalid\n"), "\(unsigned.stdout)\(unsigned.stderr)")
        #expect(try box.runEntries() == ["cof-runtime-update.lock"])
    }

    // MARK: - L1：nonce 不能靠换行混过去

    @Test("nonce 末尾或中间带换行 → bad-args", arguments: [
        PrivilegedInstallScriptTests.validNonce + "\n",
        PrivilegedInstallScriptTests.validNonce + "\nX",
        "X\n" + PrivilegedInstallScriptTests.validNonce,
    ])
    func nonceWithNewlineIsRejected(nonce: String) throws {
        let result = try PrivilegedInstallScriptTests.runScript(
            Self.args(mode: "verify-only", pkg: "/nonexistent/u.pkg", nonce: nonce)
        )
        #expect(result.stdout.hasSuffix("COF_RESULT=bad-args\n"), "\(result.stdout)")
    }

    // MARK: - M1：root 的 sh 从空环境起步（env -i）

    /// 生产的 AppleScript 去掉提权子句——其余（`quoted form of`、argv 次序、`do shell script` 的 `\r`）原样走真的 osascript。
    static func unprivilegedAppleScript() throws -> [String] {
        let pattern = #/ with prompt \(item [0-9]+ of argv\) with administrator privileges/#
        let lines = PrivilegedInstallScript.appleScriptLines
        try #require(lines.joined().matches(of: pattern).count == 1, "提权子句形状变了，先改测试")
        return lines.map { $0.replacing(pattern, with: "") }
    }

    static func osascript(_ argv: [String], extraEnvironment: [String: String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = try unprivilegedAppleScript().flatMap { ["-e", $0] } + argv
        process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExitWithoutRunLoop()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    /// 实测（本 session）：不加 `env -i` 时，调用者环境里的 `BASH_FUNC_echo%%` 会穿过 `do shell script`
    /// 把 `/bin/sh`（bash 3.2）的 `echo` 换掉——结果行就是被它写出来的。
    @Test("调用者环境里的 BASH_FUNC_* 劫持不了 root 脚本（结果行照常）")
    func exportedFunctionsDoNotReachScript() throws {
        let result = try Self.osascript(
            [PrivilegedInstallScript.rootScript] + Self.args(pkg: "relative/u.pkg") + ["prompt"],
            extraEnvironment: ["BASH_FUNC_echo%%": "() { builtin printf 'HIJACKED\\n'; }"]
        )
        let outcome = PrivilegedInstallScript.outcome(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        #expect(outcome == .finished(.badArgs, blockers: [], details: []), "\(result.stdout)|\(result.stderr)")
    }

    @Test("root 的 sh 看到的环境只有 PATH / LC_ALL（外加 sh 自己设的 PWD / SHLVL / _）")
    func scriptEnvironmentIsEmpty() throws {
        let result = try Self.osascript(
            ["/usr/bin/env"] + Self.args(pkg: "/x") + ["prompt"],
            extraEnvironment: ["COF_PROBE": "leaked", "PERL5OPT": "-Mstrict", "SHELLOPTS": "xtrace"]
        )
        #expect(result.exitCode == 0, "\(result.stderr)")
        let names = Set(result.stdout.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        #expect(names.isSubset(of: ["PATH", "LC_ALL", "PWD", "SHLVL", "_"]), "\(names.sorted())")
        #expect(result.stdout.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(result.stdout.contains("LC_ALL=C"))
    }

    // MARK: - L2：只信副本——拷出来的若不是普通文件就拒绝

    /// 检查与拷贝之间同 UID 可以换文件（竞态本身测不出来）；这里把拷贝一步换成「拷出了一个链接」，
    /// 证明拷后复核在位且有效。（不换时，同一个假包会走到 digest-mismatch——见 `noStateFileBeforeReady`。）
    @Test("拷进私有目录的副本是符号链接 → bad-source")
    func copyThatIsSymlinkIsRejected() throws {
        let box = try Sandbox()
        let pkg = try box.fakePackage()
        let result = try box.run(Self.args(pkg: pkg), extra: [
            (old: #"/bin/cp -X -P "$PKG" "$WORK/update.pkg""#, new: #"/bin/ln -s "$PKG" "$WORK/update.pkg""#, count: 1),
        ])
        #expect(result.stdout.hasSuffix("COF_RESULT=bad-source\n"), "\(result.stdout)\(result.stderr)")
    }

    // MARK: - L3：lsof 只有「退出码 0 且看得见正控制进程」才算看清了

    static let busyFixture = "p1\nftxt\nn/sbin/launchd\np90\nftxt\nD0x1\ni2\nn/usr/local/bin/container-apiserver\n"

    @Test("lsof 判定：退出码与正控制缺一不可（缺了 = 失败关闭，阻塞者报 lsof-failed）", arguments: [
        (rc: 0, output: busyFixture, listed: true, busy: "/usr/local/bin/container-apiserver\n"),
        (rc: 0, output: "p1\nftxt\nn/sbin/launchd\n", listed: true, busy: ""),
        (rc: 1, output: busyFixture, listed: false, busy: "lsof-failed\n"),
        (rc: 0, output: "p90\nftxt\nn/usr/local/bin/container-apiserver\n", listed: false, busy: "lsof-failed\n"),
        (rc: 0, output: "p10\nftxt\nn/sbin/x\n", listed: false, busy: "lsof-failed\n"),
        (rc: 0, output: "", listed: false, busy: "lsof-failed\n"),
    ])
    func lsofNeedsExitZeroAndControl(rc: Int32, output: String, listed: Bool, busy: String) throws {
        let dir = try TempDir()
        try "/usr/local/bin/container-apiserver\n".write(toFile: dir.path("paths"), atomically: true, encoding: .utf8)
        try "".write(toFile: dir.path("inodes"), atomically: true, encoding: .utf8)
        try "/container-apiserver\n".write(toFile: dir.path("bases"), atomically: true, encoding: .utf8)
        try PrivilegedInstallScript.busyAwkProgram.write(toFile: dir.path("busy.awk"), atomically: true, encoding: .utf8)
        let functions = try Self.replacing(PrivilegedInstallScript.busyFunctions, [
            (old: "/usr/sbin/lsof -nP -w -d txt -F Din", new: "lsof_stub", count: 1),
        ])
        let harness = """
        set -eu
        WORK="$1"; LSOF_RC="$2"; LSOF_OUT="$3"; CONTROL_PID=1
        lsof_stub() { printf '%s' "$LSOF_OUT"; return "$LSOF_RC"; }
        \(functions)
        if list_busy; then echo listed; else echo failed; fi
        """
        let result = try PrivilegedInstallScriptTests.shell(
            #"exec /bin/sh -c "$1" x "${@:2}""#, harness, dir.url.path, String(rc), output
        )
        #expect(result.stdout == (listed ? "listed\n" : "failed\n"), "\(result.stdout)\(result.stderr)")
        #expect(try String(contentsOfFile: dir.path("busy"), encoding: .utf8) == busy)
    }

    // MARK: - L4 + H1：墙钟 deadline；状态文件路径在 ready 那一刻才有

    /// 假时钟：每轮 lsof 耗 2 秒、sleep 耗 1 秒，WAIT = 3。按墙钟：2 轮就超时（t = 2 → 睡到 3 → t = 5 ≥ 3）；
    /// 按轮数数（旧实现）要 3 轮。`busyRounds` 轮之后保护集合空闲 → 跳出等待、往下走。
    static func runWait(busyRounds: Int) throws -> (stdout: String, calls: Int, states: String) {
        let dir = try TempDir()
        let section = try replacing(PrivilegedInstallScript.waitSection, [
            (old: "/bin/date +%s", new: "clock_now", count: 2),
            (old: "/bin/sleep 1", new: "clock_sleep", count: 1),
        ])
        let harness = """
        set -eu
        WORK="$1"; RUNDIR="$1"; NONCE=N; WAIT=3; BUSY_ROUNDS="$2"
        STATE=
        echo 0 > "$WORK/clock"; : > "$WORK/calls"; : > "$WORK/states"
        clock_now() { /bin/cat "$WORK/clock"; }
        clock_sleep() { echo $(( $(/bin/cat "$WORK/clock") + 1 )) > "$WORK/clock"; }
        list_busy() {
            echo $(( $(/bin/cat "$WORK/clock") + 2 )) > "$WORK/clock"
            echo x >> "$WORK/calls"
            if [ "$(/usr/bin/wc -l < "$WORK/calls")" -le "$BUSY_ROUNDS" ]; then
                echo /usr/local/bin/container-apiserver > "$WORK/busy"
            else
                : > "$WORK/busy"
            fi
        }
        report_busy() { echo "COF_BUSY=$(/bin/cat "$WORK/busy")"; }
        write_state() { echo "$STATE $*" >> "$WORK/states"; }
        finish() { echo "COF_RESULT=$1"; exit 0; }
        \(section)
        echo "COF_RESULT=proceeded"
        """
        let result = try PrivilegedInstallScriptTests.shell(#"exec /bin/sh -c "$1" x "${@:2}""#, harness, dir.url.path, String(busyRounds))
        let calls = try String(contentsOfFile: dir.path("calls"), encoding: .utf8).split(separator: "\n").count
        return (result.stdout + result.stderr, calls, try String(contentsOfFile: dir.path("states"), encoding: .utf8))
    }

    @Test("一直忙 → 按墙钟 2 轮就 stop-timeout（不是按轮数的 3 轮）；ready 只写一次，路径 = RUNDIR/…nonce")
    func waitUsesWallClockDeadline() throws {
        let run = try Self.runWait(busyRounds: 99)
        #expect(run.stdout == "COF_BUSY=/usr/local/bin/container-apiserver\nCOF_RESULT=stop-timeout\n")
        #expect(run.calls == 2)
        #expect(run.states.hasSuffix("/cof-runtime-update.N phase=ready\n"))
        #expect(run.states.split(separator: "\n").count == 1)
    }

    @Test("忙一轮后空闲 → 跳出等待往下走")
    func waitProceedsWhenFree() throws {
        let run = try Self.runWait(busyRounds: 1)
        #expect(run.stdout == "COF_RESULT=proceeded\n")
        #expect(run.calls == 2)
    }

    /// H1 第三层的结构面：`STATE=` 在整份脚本里只有两处——开头置空、写 ready 的前一行。
    @Test("状态文件路径只在写 ready 的前一行赋值")
    func stateAssignedOnlyRightBeforeReady() {
        let script = PrivilegedInstallScript.rootScript
        #expect(script.components(separatedBy: "\nSTATE=").count - 1 == 2)
        #expect(PrivilegedInstallScript.waitSection.hasPrefix(
            "STATE=$RUNDIR/cof-runtime-update.$NONCE\nwrite_state \"phase=ready\"\n"
        ))
    }

    // MARK: - M2：包的 identifier / version 绑定到这次的目标

    static let realHeader = #"<pkg-info overwrite-permissions="true" relocatable="false" identifier="com.apple.container-installer" postinstall-action="none" version="1.4.1" format-version="2" generator-version="InstallCmds-860.14 (24G84)" install-location="/usr/local" auth="root">"#

    /// PackageInfo（`nil` = 包里没有这个成员）、目标版本、是否放行。第一例是 1.4.1 真包 PackageInfo 的起始标签原文。
    @Test("PackageInfo 核对：起始标签里 identifier 与 version 都对上才放行", arguments: [
        (info: "<?xml version=\"1.0\"?>\n\(realHeader)\n  <payload/>\n</pkg-info>\n", target: "1.4.1", ok: true),
        (info: "<?xml version=\"1.0\"?>\n\(realHeader)\n</pkg-info>\n", target: "1.4.2", ok: false),
        (info: #"<pkg-info identifier="com.apple.container-installer" version="1.4.10">"#, target: "1.4.1", ok: false),
        (info: #"<pkg-info identifier="com.apple.container-installer.evil" version="1.4.1">"#, target: "1.4.1", ok: false),
        (info: #"<pkg-info identifier="com.apple.container-installer" format-version="1.4.1" version="9.9.9">"#, target: "1.4.1", ok: false),
        (info: #"<pkg-info identifier="com.apple.container-installer" version="1.3.0"><bundle version="1.4.1"/></pkg-info>"#, target: "1.4.1", ok: false),
        (info: "<pkg-info\n\tidentifier=\"com.apple.container-installer\"\n\tversion=\"1.4.1\">\n</pkg-info>", target: "1.4.1", ok: true),
        (info: nil, target: "1.4.1", ok: false),
    ] as [(info: String?, target: String, ok: Bool)])
    func packageInfoIsBoundToTarget(info: String?, target: String, ok: Bool) throws {
        let dir = try TempDir()
        let staging = dir.path("staging")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let member = info == nil ? "Distribution" : "PackageInfo"
        try (info ?? "<installer-gui-script/>").write(toFile: "\(staging)/\(member)", atomically: true, encoding: .utf8)
        let work = dir.path("work")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        // `xar -c` 不认 `-C`（报「Error adding file」却**退出 0**——第一版测试据此造出空包，负例全部「恰好通过」）：
        // 进目录再打包，并列出成员确认包里真有它。
        let xar = try PrivilegedInstallScriptTests.shell(
            #"cd "$2" && /usr/bin/xar -cf "$1" "$3" && /usr/bin/xar -tf "$1""#, "\(work)/update.pkg", staging, member
        )
        try #require(xar.stdout == "\(member)\n", "\(xar.stdout)\(xar.stderr)")

        let result = try Self.runIdentity(work: work, target: target)
        #expect(result == (ok ? "COF_RESULT=identity-ok\n" : "COF_RESULT=unexpected-version\n"))
    }

    @Test("不是 xar 包 → unexpected-version")
    func packageInfoFromNonArchive() throws {
        let dir = try TempDir()
        try Data("not a xar".utf8).write(to: URL(fileURLWithPath: dir.path("update.pkg")))
        #expect(try Self.runIdentity(work: dir.url.path, target: "1.4.1") == "COF_RESULT=unexpected-version\n")
    }

    static func runIdentity(work: String, target: String) throws -> String {
        let harness = """
        set -eu
        WORK="$1"; TARGET="$2"
        finish() { echo "COF_RESULT=$1"; exit 0; }
        \(PrivilegedInstallScript.packageIdentity)
        echo "COF_RESULT=identity-ok"
        """
        let result = try PrivilegedInstallScriptTests.shell(#"exec /bin/sh -c "$1" x "${@:2}""#, harness, work, target)
        return result.stdout + result.stderr
    }

    // MARK: - INFO：SIGKILL 留下的 root 工作目录，下一个任务持锁后清掉

    @Test("持锁后清掉残留的工作目录；名字不符 / 符号链接 / 普通文件一律不碰（也不跟随链接）")
    func sweepsStaleWorkDirectories() throws {
        let box = try Sandbox()
        let pkg = try box.fakePackage()
        let fm = FileManager.default
        let stale = "\(box.tmp)/cof-runtime-update.abc123"
        try fm.createDirectory(atPath: stale, withIntermediateDirectories: true)
        try Data("118MB".utf8).write(to: URL(fileURLWithPath: "\(stale)/update.pkg"))
        let shortName = "\(box.tmp)/cof-runtime-update.abc12"
        try fm.createDirectory(atPath: shortName, withIntermediateDirectories: true)
        let victim = box.dir.path("victim")
        try fm.createDirectory(atPath: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: "\(victim)/keep"))
        let link = "\(box.tmp)/cof-runtime-update.zzzzzz"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: victim)
        let plainFile = "\(box.tmp)/cof-runtime-update.qqqqqq"
        try Data("f".utf8).write(to: URL(fileURLWithPath: plainFile))

        let result = try box.run(Self.args(pkg: pkg))
        #expect(result.stdout.hasSuffix("COF_RESULT=digest-mismatch\n"), "\(result.stdout)\(result.stderr)")

        #expect(!fm.fileExists(atPath: stale))
        #expect(fm.fileExists(atPath: shortName))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link)) == victim)
        #expect(fm.fileExists(atPath: "\(victim)/keep"))
        #expect(fm.fileExists(atPath: plainFile))
        // 本次任务自己的工作目录由 EXIT trap 清掉——tmp 里只剩上面那三个。
        #expect(try fm.contentsOfDirectory(atPath: box.tmp).sorted()
            == ["cof-runtime-update.abc12", "cof-runtime-update.qqqqqq", "cof-runtime-update.zzzzzz"])
    }

    // MARK: - INFO：锁文件被换成符号链接时不跟随（目录迁到 /private/var/db 之后是纵深）

    @Test("锁文件是符号链接（指向已有文件 / 悬空）→ busy，且不碰链接目标")
    func lockSymlinkIsRejected() throws {
        let box = try Sandbox()
        let pkg = try box.fakePackage()
        let victim = box.dir.path("victim")
        try Data("keep".utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim)
        let lock = "\(box.run)/cof-runtime-update.lock"

        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: victim)
        let existing = try box.run(Self.args(pkg: pkg))
        #expect(existing.stdout.contains("COF_DETAIL=lock-is-symlink\n"), "\(existing.stdout)")
        #expect(existing.stdout.hasSuffix("COF_RESULT=busy\n"))
        let attributes = try FileManager.default.attributesOfItem(atPath: victim)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try String(contentsOfFile: victim, encoding: .utf8) == "keep")

        try FileManager.default.removeItem(atPath: lock)
        let dangling = box.dir.path("would-be-created")
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: dangling)
        let result = try box.run(Self.args(pkg: pkg))
        #expect(result.stdout.hasSuffix("COF_RESULT=busy\n"), "\(result.stdout)")
        #expect(!FileManager.default.fileExists(atPath: dangling))
    }

    /// `-L` 检查之后、建文件 / chmod 之前被换上链接（竞态窗口）：noclobber 让悬空链接写不穿，`chmod -h` 不跟随链接。
    /// 这两道平时被 `-L` 检查遮住、测不到——这里拿掉 `-L` 检查来模拟「检查时还不是链接」。
    @Test("竞态窗口里换上的链接：悬空的写不穿、已有目标的权限不被改")
    func lockRaceWindowDoesNotFollowSymlinks() throws {
        let noCheck = [(
            old: "    if [ -L \"$LOCK\" ]; then printf 'COF_DETAIL=%s\\n' lock-is-symlink; finish busy; fi\n", new: "", count: 1
        )]
        let box = try Sandbox()
        let pkg = try box.fakePackage()
        let lock = "\(box.run)/cof-runtime-update.lock"

        let dangling = box.dir.path("would-be-created")
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: dangling)
        let danglingRun = try box.run(Self.args(pkg: pkg), extra: noCheck)
        #expect(danglingRun.stdout.hasSuffix("COF_RESULT=busy\n"), "\(danglingRun.stdout)\(danglingRun.stderr)")
        #expect(!FileManager.default.fileExists(atPath: dangling))

        try FileManager.default.removeItem(atPath: lock)
        let victim = box.dir.path("victim")
        try Data("keep".utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim)
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: victim)
        _ = try box.run(Self.args(pkg: pkg), extra: noCheck)
        let attributes = try FileManager.default.attributesOfItem(atPath: victim)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try String(contentsOfFile: victim, encoding: .utf8) == "keep")
    }
}
