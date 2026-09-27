import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T5（纯部分）：root 脚本、osascript 参数、结果契约、状态文件、lsof 判定。
///
/// 这里的「用真 sh 跑脚本」都**不需要特权**，只覆盖在碰状态目录之前就结束的路径
/// （参数校验、源文件检查、digest、签名）。持锁 / 状态文件 / 等停机 / installer 由 S1（F23）与 T13 真机证明。
@Suite("PrivilegedInstallScript：常量脚本、argv 传参、结果只认 COF_RESULT")
struct PrivilegedInstallScriptTests {

    static let digest = SHA256Digest(hex: String(repeating: "a", count: 64))!
    static let nonce = UUID(uuidString: "9BEB0556-2A54-4600-9C92-318F1F6DDBDC")!

    // MARK: - osascript 参数：AppleScript 源码与 sh 文本都是常量

    @Test("argv 结构：-e 常量行 + 脚本 + install + 各参数 + prompt")
    func argumentStructure() {
        let args = PrivilegedInstallScript.osascriptArguments(
            packagePath: "/tmp/it's \"x\"/u.pkg", digest: Self.digest, ownerUID: 501,
            nonce: Self.nonce, waitSeconds: 300, target: RuntimeVersion(major: 1, minor: 5, patch: 0), prompt: "$(whoami) `id`"
        )
        let scriptLines = PrivilegedInstallScript.appleScriptLines
        #expect(Array(args.prefix(scriptLines.count * 2)) == scriptLines.flatMap { ["-e", $0] })
        #expect(Array(args.dropFirst(scriptLines.count * 2)) == [
            PrivilegedInstallScript.rootScript, "install", "/tmp/it's \"x\"/u.pkg", Self.digest.hex, "501",
            "9BEB0556-2A54-4600-9C92-318F1F6DDBDC", "300", "1.5.0", "$(whoami) `id`",
        ])
    }

    /// 注入在结构上写不出来：AppleScript 只用 `quoted form of (item N of argv)` 引用参数，源码里没有任何用户数据。
    /// root 的 sh 从空环境起步（安全评审 M1；行为由 `PrivilegedInstallScriptHardeningTests` 走真 osascript 证明）。
    @Test("AppleScript 源码只经 quoted form of 引用 argv，经 env -i 起 sh，并以管理员权限运行")
    func appleScriptIsConstant() {
        let source = PrivilegedInstallScript.appleScriptLines.joined(separator: "\n")
        for item in 1...8 {
            #expect(source.contains("quoted form of (item \(item) of argv)"))
        }
        #expect(source.contains("with prompt (item 9 of argv) with administrator privileges"))
        #expect(!source.contains("item 10"))
        #expect(PrivilegedInstallScript.appleScriptLines[1].hasPrefix(
            "do shell script \"/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /bin/sh -c \" & quoted form of (item 1 of argv)"
        ))
    }

    /// 两侧签名契约同源：root 脚本里的三条规则与 `PackageSignature` 的常量逐字相同（改一边不改另一边 → 红）。
    @Test("root 脚本与 PackageSignature 用同一套常量")
    func signatureContractIsShared() {
        let script = PrivilegedInstallScript.rootScript
        #expect(script.contains("TEAM=\(PackageSignature.teamID)"))
        #expect(script.contains("'\(PackageSignature.statusLine)'"))
        #expect(script.contains("'\(PackageSignature.notarizationLine)'"))
        #expect(script.contains("\"\(PackageSignature.leafPrefix)\"*\" ($TEAM)\""))
        #expect(script.contains("LOCK=$RUNDIR/cof-runtime-update.lock"))
        #expect(RuntimeCommands.lockPath == "/private/var/db/cof-runtime-update/cof-runtime-update.lock")
        // digest 走 C 程序，不走 perl 脚本 shasum（安全评审 M1）；PackageInfo 与 receipt 认同一个 identifier（M2）。
        #expect(script.contains("/sbin/sha256 -q"))
        #expect(!script.contains("shasum"))
        #expect(script.contains(#"*' identifier="com.apple.container-installer"'*"#))
        #expect(script.contains("/usr/sbin/pkgutil --files com.apple.container-installer"))
    }

    // MARK: - 结果契约（AD8）

    @Test("exit 0：以 \\r 或 \\n 分行，取 COF_RESULT，收集 BUSY / DETAIL")
    func parsesFinishedOutcome() {
        let stdout = "COF_BUSY=/usr/local/bin/container-apiserver\rCOF_DETAIL=installer-exit=1\rCOF_RESULT=stop-timeout\r"
        #expect(PrivilegedInstallScript.outcome(exitCode: 0, stdout: stdout, stderr: "") == .finished(
            .stopTimeout, blockers: ["/usr/local/bin/container-apiserver"], details: ["installer-exit=1"]
        ))
        #expect(PrivilegedInstallScript.outcome(exitCode: 0, stdout: "COF_RESULT=installed\n", stderr: "")
            == .finished(.installed, blockers: [], details: []))
    }

    @Test("每个结果名都能解析回来", arguments: PrivilegedJobResult.allCases)
    func everyResultRoundTrips(result: PrivilegedJobResult) {
        #expect(PrivilegedInstallScript.outcome(exitCode: 0, stdout: "COF_RESULT=\(result.rawValue)", stderr: "")
            == .finished(result, blockers: [], details: []))
        #expect(PrivilegedInstallScript.rootScript.contains(result.rawValue))
    }

    @Test("非 0 且最后一行以 (-128) 结尾 → 已取消")
    func parsesCancel() {
        #expect(PrivilegedInstallScript.outcome(exitCode: 1, stdout: "", stderr: "0:180: execution error: User canceled. (-128)\n")
            == .cancelled)
        #expect(PrivilegedInstallScript.outcome(exitCode: 1, stdout: "", stderr: "0:180: execution error: User canceled. (-128)\r\n\n")
            == .cancelled)
    }

    /// 安全评审 L5：AppleScript 把脚本的 stderr 包进错误文本、**最后**附上退出码（F15）——
    /// `(-128)` 出现在别处（脚本自己的输出、路径名）不是取消；取消的唯一形态是最后一行以 `(-128)` 结尾。
    @Test("(-128) 不在最后一行末尾 → 不是取消", arguments: [
        "0:180: execution error: sh: /tmp/x (-128): No such file (1)\n",
        "noise (-128)\n0:180: execution error: boom (1)\n",
        "0:180: execution error: User canceled. (-128) (1)",
    ])
    func minus128ElsewhereIsNotCancel(stderr: String) {
        guard case .unknown = PrivilegedInstallScript.outcome(exitCode: 1, stdout: "", stderr: stderr) else {
            Issue.record("\(stderr) must be unknown"); return
        }
    }

    /// 非 0 = 脚本没按契约结束（意外失败、osascript 被杀）→ 未知；**不**从 stderr 里嗅 COF_RESULT（F15 的包装会让它不可靠）。
    @Test("非 0 无 (-128) → unknown；0 却无结果行 → unknown；结果名不认识 → unknown")
    func parsesUnknown() {
        guard case .unknown = PrivilegedInstallScript.outcome(exitCode: 1, stdout: "", stderr: "execution error: COF_RESULT=installed (1)") else {
            Issue.record("non-zero must be unknown"); return
        }
        guard case .unknown = PrivilegedInstallScript.outcome(exitCode: 0, stdout: "hello\r", stderr: "") else {
            Issue.record("missing result must be unknown"); return
        }
        guard case .unknown = PrivilegedInstallScript.outcome(exitCode: 0, stdout: "COF_RESULT=whatever", stderr: "") else {
            Issue.record("unknown name must be unknown"); return
        }
    }

    // MARK: - 状态文件

    @Test("状态文件：ready / done+result / 读不懂")
    func parsesStateFile() {
        #expect(PrivilegedInstallScript.parseStateFile("phase=ready\n") == .ready)
        #expect(PrivilegedInstallScript.parseStateFile("phase=done\nresult=install-failed\n") == .done(.installFailed))
        #expect(PrivilegedInstallScript.parseStateFile("phase=done\n") == .done(nil))
        #expect(PrivilegedInstallScript.parseStateFile("garbage") == nil)
        #expect(PrivilegedInstallScript.stateFilePath(nonce: Self.nonce)
            == "/private/var/db/cof-runtime-update/cof-runtime-update.9BEB0556-2A54-4600-9C92-318F1F6DDBDC")
    }

    // MARK: - lsof 判定（AD7，F22 三种形态）

    @Test("awk 判定：路径 / D:i / 已删除的 /basename 任一命中；无关进程不命中")
    func busyMatcher() throws {
        let dir = try TempDir()
        try "/usr/local/bin/container-apiserver\n/usr/local/libexec/container/plugins/x/bin/x\n/usr/local/bin/update-container.sh\n"
            .write(toFile: dir.path("paths"), atomically: true, encoding: .utf8)
        try "0x100000e:111\n".write(toFile: dir.path("inodes"), atomically: true, encoding: .utf8)
        try "/container-apiserver\n/x\n".write(toFile: dir.path("bases"), atomically: true, encoding: .utf8)
        try PrivilegedInstallScript.busyAwkProgram.write(toFile: dir.path("busy.awk"), atomically: true, encoding: .utf8)
        let lsof = [
            "p1", "ftxt", "D0x100000e", "i222", "n/usr/local/bin/container-apiserver",   // ① 路径（含 rename 替换后的旧 inode）
            "p2", "ftxt", "D0x100000e", "i111", "n/private/tmp/hardlink-to-x",            // ② 硬链接：D:i
            "p3", "ftxt", "D0x100000e", "i333", "n/x",                                   // ③ 已删除：/basename
            "p4", "ftxt", "D0x100000e", "i444", "n/usr/bin/sleep",                       // 无关
            "p5", "ftxt", "D0x100000f", "i111", "n/other/volume",                        // 同 inode 不同设备：无关
            "p6", "ftxt", "D0x100000e", "i555", "n/usr/local/bin/update-container.sh",   // 脚本不是 txt 执行者，但路径在集合里 → 仍算（偏保守）
        ].joined(separator: "\n") + "\n"
        try lsof.write(toFile: dir.path("lsof"), atomically: true, encoding: .utf8)

        let result = try Self.shell(
            #"/usr/bin/awk -v paths="$1/paths" -v inodes="$1/inodes" -v bases="$1/bases" -f "$1/busy.awk" "$1/lsof""#,
            dir.url.path
        )
        #expect(result.stdout.split(separator: "\n").map(String.init) == [
            "/usr/local/bin/container-apiserver", "/private/tmp/hardlink-to-x", "/x", "/usr/local/bin/update-container.sh",
        ])
    }

    // MARK: - 用真 sh 跑生产脚本（不需要特权的失败关闭路径）

    static func runScript(_ args: [String]) throws -> ProcessResult {
        try runScript(PrivilegedInstallScript.rootScript, args)
    }

    /// 与生产**同形**的调用：`env -i PATH=… LC_ALL=C /bin/sh -c <script> cof-update <args…>`（前缀直接取生产常量，改一边另一边跟着变）。
    /// 于是 smoke 里 pkgutil / xar / lsof / sha256 跑在与 root 相同的空环境里（除了身份）。
    static func runScript(_ script: String, _ args: [String]) throws -> ProcessResult {
        try shell("exec \(PrivilegedInstallScript.shellInvocation)\"$1\" cof-update \"${@:2}\"", [script] + args)
    }

    static let validNonce = "9BEB0556-2A54-4600-9C92-318F1F6DDBDC"
    static var uid: String { String(getuid()) }
    static let hex = String(repeating: "a", count: 64)

    /// 每组只坏一个字段（其余合法——「合法参数不被拒」那条守着这一点，见 `PrivilegedInstallScriptHardeningTests`）。
    @Test("参数非法 → bad-args（在碰任何文件之前）", arguments: [
        ["install"],
        ["frobnicate", "/tmp/x", hex, "501", validNonce, "300", "1.4.1"],
        ["verify-only", "/tmp/x", String(repeating: "A", count: 64), "501", validNonce, "300", "1.4.1"],
        ["verify-only", "/tmp/x", String(repeating: "a", count: 63), "501", validNonce, "300", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "5o1", validNonce, "300", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "501", validNonce.lowercased(), "300", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "501", validNonce, "0", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "501", validNonce, "601", "1.4.1"],
        // R2：前导零（`[ -ge ]` 按十进制过了校验，`$((…))` 按八进制在 ready 之后才报错）
        ["verify-only", "/tmp/x", hex, "501", validNonce, "09", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "501", validNonce, "010", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "0501", validNonce, "300", "1.4.1"],
        ["verify-only", "relative/x", hex, "501", validNonce, "300", "1.4.1"],
        ["verify-only", "/tmp/x", hex, "501", validNonce, "300", "1.4.1", "extra"],
        ["verify-only", "/tmp/x", hex, "501", validNonce, "300"],
    ] + ["", "1.4", "1.4.1.2", "v1.4.1", "1..4", ".1.4", "1.4.", "1.4.a", "1.4.1\n", "1.4.1 ", String(repeating: "1", count: 31) + ".1.1"]
        .map { ["verify-only", "/tmp/x", hex, "501", validNonce, "300", $0] })
    func rejectsBadArguments(args: [String]) throws {
        let result = try Self.runScript(args)
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasSuffix("COF_RESULT=bad-args\n"))
    }

    @Test("源文件不存在 / 是符号链接 / 属主不对 → bad-source")
    func rejectsBadSource() throws {
        let dir = try TempDir()
        let real = dir.path("real.pkg")
        try Data("x".utf8).write(to: URL(fileURLWithPath: real))
        let link = dir.path("link.pkg")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let hex = String(repeating: "a", count: 64)

        for (path, owner) in [(dir.path("missing.pkg"), Self.uid), (link, Self.uid), (real, "0")] {
            let result = try Self.runScript(["verify-only", path, hex, owner, Self.validNonce, "1", "1.4.1"])
            #expect(result.stdout.hasSuffix("COF_RESULT=bad-source\n"), "\(path) owner=\(owner)")
        }
    }

    /// digest 由 `shasum`（独立实现）算出期望值，root 侧用 `/sbin/sha256`——两个实现对上，才走到签名那一步。
    @Test("digest 不符 → digest-mismatch；digest 对但不是签名 pkg → signature-invalid")
    func failsClosedOnDigestAndSignature() throws {
        let dir = try TempDir()
        let file = dir.path("fake.pkg")
        try Data("not a package".utf8).write(to: URL(fileURLWithPath: file))
        let actual = try Self.shell(#"/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'"#, file).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wrong = try Self.runScript(["verify-only", file, String(repeating: "b", count: 64), Self.uid, Self.validNonce, "1", "1.4.1"])
        #expect(wrong.stdout.hasSuffix("COF_RESULT=digest-mismatch\n"))

        let unsigned = try Self.runScript(["verify-only", file, actual, Self.uid, Self.validNonce, "1", "1.4.1"])
        #expect(unsigned.stdout.hasSuffix("COF_RESULT=signature-invalid\n"))
    }

    /// R4-2：`set -e` 下 installer 失败必须**走到**写结果那一步，而不是被 `-e` 当场杀掉。
    /// 只这一段离线跑：前面换成最小桩（finish / list_busy），INSTALLER 换成返回 1 的 `/usr/bin/false`。
    @Test("installer 失败 → install-failed（受控块，不被 set -e 杀掉）")
    func installerFailureIsReported() throws {
        let harness = """
        set -eu
        WORK=$(/usr/bin/mktemp -d)
        STATE=
        INSTALLER=/usr/bin/false
        finish() { echo "COF_RESULT=$1"; exit 0; }
        list_busy() { : > "$WORK/busy"; return 0; }
        report_busy() { :; }
        """
        let result = try Self.shell(#"exec /bin/sh -c "$1" x"#, harness + "\n" + PrivilegedInstallScript.installSegment)
        #expect(result.stdout.contains("COF_DETAIL=installer-exit=1\n"))
        #expect(result.stdout.hasSuffix("COF_RESULT=install-failed\n"))
    }

    // MARK: - helpers

    static func shell(_ command: String, _ args: String...) throws -> ProcessResult {
        try shell(command, args)
    }

    static func shell(_ command: String, _ args: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command, "bash"] + args
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
}

/// 测试用临时目录，析构时删除。
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cof-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// root 脚本 smoke（Plan §7）：**非特权**、`verify-only`、生产同一份脚本，喂真 pkg。
/// 证明复验逻辑与保护集合在真输入上的判定；**不**证明持锁 / 状态文件 / installer（那些由 S1 与 T13 证明）。
///
/// `INTEGRATION=1 COF_SIGNED_PKG=<1.4.1 签名包> COF_UNSIGNED_PKG=<unsigned 包> swift test --filter PrivilegedInstallScriptSmoke`
@Suite(
    "PrivilegedInstallScript smoke（INTEGRATION=1，真 pkg）",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1"
        && ProcessInfo.processInfo.environment["COF_SIGNED_PKG"] != nil)
)
struct PrivilegedInstallScriptSmokeTests {

    static let signed141Digest = "c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4"
    static let unsigned141Digest = "7f2784bdd506c95347f8130382004a600800ec8f306162ad9211d83378ec3a68"

    /// 拷一份到自己名下（源文件属主必须 == 传入的 uid）。
    func copy(_ env: String) throws -> (TempDir, String) {
        let source = try #require(ProcessInfo.processInfo.environment[env])
        let dir = try TempDir()
        let path = dir.path("u.pkg")
        try FileManager.default.copyItem(atPath: source, toPath: path)
        return (dir, path)
    }

    @Test("真 1.4.1 签名包 → verified；运行时在跑时 COF_BUSY 含 apiserver")
    func verifiesSignedPackage() async throws {
        let (dir, path) = try copy("COF_SIGNED_PKG")
        _ = dir
        let result = try PrivilegedInstallScriptTests.runScript(
            PrivilegedInstallScriptHardeningTests.args(mode: "verify-only", pkg: path, sha: Self.signed141Digest)
        )
        let outcome = PrivilegedInstallScript.outcome(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        guard case .finished(.verified, let blockers, _) = outcome else {
            Issue.record("expected verified, got \(outcome)"); return
        }
        if await RuntimeCommands().isRuntimeRunning() {
            #expect(blockers.contains("/usr/local/bin/container-apiserver"))
        }
    }

    /// 安全评审 M2：签名有效的真包，只要 PackageInfo 的 version 不是这次要装的版本，就在 ready 之前失败关闭。
    @Test("真 1.4.1 签名包 + 目标版本 1.4.2 / 1.4.10 → unexpected-version", arguments: ["1.4.2", "1.4.10"])
    func rejectsVersionMismatch(target: String) throws {
        let (dir, path) = try copy("COF_SIGNED_PKG")
        _ = dir
        let result = try PrivilegedInstallScriptTests.runScript(
            PrivilegedInstallScriptHardeningTests.args(mode: "verify-only", pkg: path, sha: Self.signed141Digest, target: target)
        )
        #expect(result.stdout.hasSuffix("COF_RESULT=unexpected-version\n"), "\(result.stdout)")
    }

    @Test("真 unsigned 包（digest 对）→ signature-invalid")
    func rejectsUnsignedPackage() throws {
        guard ProcessInfo.processInfo.environment["COF_UNSIGNED_PKG"] != nil else { return }
        let (dir, path) = try copy("COF_UNSIGNED_PKG")
        _ = dir
        let result = try PrivilegedInstallScriptTests.runScript(
            PrivilegedInstallScriptHardeningTests.args(mode: "verify-only", pkg: path, sha: Self.unsigned141Digest)
        )
        #expect(result.stdout.hasSuffix("COF_RESULT=signature-invalid\n"))
    }

    /// install 模式、重定位到临时目录、非特权身份：真签名包走完复验 → **ready 才出现状态文件**（H1）→ 运行时在跑，
    /// lsof（正控制 = 自己的 shell，L3）看得见 apiserver → 墙钟 2 秒后 stop-timeout（L4）→ 状态文件 done。
    /// 运行时不在跑时 root 会往 installer 走——这里把 INSTALLER 换成 `/usr/bin/false`，绝不真装。
    @Test("install 模式（重定位）：ready → stop-timeout，状态文件 ready 之后才有、以 done 结束")
    func installModeTimesOutWhileRuntimeRuns() async throws {
        guard await RuntimeCommands().isRuntimeRunning() else { return }
        let (dir, path) = try copy("COF_SIGNED_PKG")
        _ = dir
        let box = try PrivilegedInstallScriptHardeningTests.Sandbox()
        let started = ContinuousClock.now
        let result = try box.run(
            PrivilegedInstallScriptHardeningTests.args(pkg: path, sha: Self.signed141Digest, wait: "2"),
            extra: [(old: "INSTALLER=/usr/sbin/installer\n", new: "INSTALLER=/usr/bin/false\n", count: 1)]
        )
        let elapsed = ContinuousClock.now - started

        #expect(result.stdout.contains("COF_BUSY=/usr/local/bin/container-apiserver\n"), "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.hasSuffix("COF_RESULT=stop-timeout\n"))
        #expect(elapsed < .seconds(15), "墙钟 deadline：2 秒上限不该拖成十几秒（\(elapsed)）")
        let stateFile = "\(box.run)/cof-runtime-update.\(PrivilegedInstallScriptTests.validNonce)"
        #expect(try String(contentsOfFile: stateFile, encoding: .utf8) == "phase=done\nresult=stop-timeout\n")
    }

    /// user 侧的 Swift 判定与 root 侧的 sh 判定对同一个真 pkg 必须一致。
    @Test("同一真 pkg：PackageSignature（Swift）与脚本（sh）结论一致")
    func swiftAndShellAgree() throws {
        let (dir, path) = try copy("COF_SIGNED_PKG")
        _ = dir
        let pkgutil = try PrivilegedInstallScriptTests.shell("LC_ALL=C /usr/sbin/pkgutil --check-signature \"$1\"", path)
        #expect(PackageSignature.evaluate(pkgutilOutput: pkgutil.stdout, exitCode: pkgutil.exitCode) == .trusted)
    }
}
