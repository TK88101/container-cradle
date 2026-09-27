import Foundation

/// root 任务的结局名（AD8）。rawValue 就是脚本 stdout 里 `COF_RESULT=` 后面那个词。
public enum PrivilegedJobResult: String, Sendable, Equatable, CaseIterable {
    case installed
    /// 仅 `verify-only` 模式（smoke 测试用）。
    case verified
    case badArgs = "bad-args"
    case badSource = "bad-source"
    case digestMismatch = "digest-mismatch"
    case signatureInvalid = "signature-invalid"
    case signerUntrusted = "signer-untrusted"
    /// 签名有效，但包的 identifier / version 不是这次要装的那个（安全评审 M2：元数据出错不许静默降级）。
    case unexpectedVersion = "unexpected-version"
    case unexpectedPayload = "unexpected-payload"
    /// 另一个 root 任务持着锁（或锁文件被换成了符号链接）。
    case busy
    /// 等不到「本包要覆盖的可执行文件」全部停止运行。
    case stopTimeout = "stop-timeout"
    case installFailed = "install-failed"
    /// 装后复查**证明不了没有混跑**：有进程映射着本包的文件（未必是运行时——一个 `container system logs -f`、
    /// 一个扫描新文件的安全软件都会），或复查本身看不清（`lsof-failed`）。App 按客观状态复原，不据此推断「运行时被别人起来了」。
    case raced
    /// 仅见于状态文件：installer 之前被信号打断。
    case interrupted
    /// 仅见于状态文件：脚本意外失败（`set -e` 兜底）。
    case error
}

/// osascript 这一次运行的结局（AD8：进程退出码只区分 0 / 非 0）。
public enum PrivilegedJobOutcome: Sendable, Equatable {
    case finished(PrivilegedJobResult, blockers: [String], details: [String])
    /// 用户在系统密码框点了取消（AppleScript `-128`）。
    case cancelled
    /// 没按契约结束：意外失败、osascript 被杀、结果名不认识。按「可能改过系统」处理（走恢复）。
    case unknown(String)
}

/// root 写的 nonce 状态文件（root→App 的唯一信道，AD3 / AD9）。
public enum PrivilegedJobStateFile: Sendable, Equatable {
    case ready
    /// `nil` = done 但没写结果（不应出现；按未知处理）。
    case done(PrivilegedJobResult?)
}

/// root 升级任务的**常量**脚本与 osascript 参数（Day 22 T5，Plan §5.3 / AD3–AD8）。纯值，住 core 可测。
///
/// ## 注入在结构上写不出来
///
/// AppleScript 源码与 sh 文本都是**编译期常量**；一切变量（pkg 路径、digest、uid、nonce、等待秒数、目标版本、提示文字）
/// 只作为 argv 传入，AppleScript 里只用 `quoted form of (item N of argv)` 引用（F15 实测：`'` `"` `$()` 反引号全部按字面到达）。
/// root 侧再按形状校验一遍参数（`bad-args`）。root 的 sh 从**空环境**起步（`env -i`，安全评审 M1）。
///
/// ## 脚本做什么（一句话一步，细节见各段注释）
///
/// 参数校验 →（install）fd 形式持 `lockf` 锁、清旧状态文件与残留工作目录 → 源文件检查 → 拷进 root 私有目录、此后只信副本 →
/// digest 与签名复验（与 `PackageSignature` 同一契约）→ 核对包的 identifier / version → 算保护集合（payload ∪ receipt）→
/// （verify-only 到此为止）→ 写 `phase=ready` → 等保护集合里的可执行文件全部停止运行 → installer（受控块）→
/// 装后再查一次 → `COF_RESULT=installed`。**每个可预期结局都 exit 0**，结果只写 stdout 最后一行。
public enum PrivilegedInstallScript {

    /// root 等「运行时停下」的上限（Plan §5.3：大于 App 的 stop 超时 120 秒）。墙钟秒数（安全评审 L4）。
    public static let productionWaitSeconds = 300
    /// 锁与状态文件的目录（R2：由 `/private/var/run` 迁来）。`/private/var/run` 是 `root:daemon 0775`、**无 sticky**——
    /// 本机就有以 daemon 身份常驻的网络服务（XAMPP httpd），它能在里面改名 / 替换条目：锁可被换 inode（互斥失效），
    /// 状态文件可被伪造，`write_state` 按路径写的临时文件可被换成符号链接（root 截断改写任意文件）。
    /// `/private/var/db` 的父链（`/`、`/private`、`/private/var`、`/private/var/db`）全是 root:wheel 0755——非 root 主体在里面什么都改不了。
    /// 附带：状态文件跨重启保留，崩溃恢复（AD9）读得到上一次的结果。
    static let stateDirectory = "/private/var/db/cof-runtime-update"
    static let workDirectory = "/private/var/tmp"
    /// 上游安装包的 identifier：root 核对 PackageInfo（M2）与读已装 receipt（AD7）用的是同一个。
    static let packageIdentifier = "com.apple.container-installer"

    public static func stateFilePath(nonce: UUID) -> String {
        "\(stateDirectory)/cof-runtime-update.\(nonce.uuidString)"
    }

    // MARK: - osascript

    /// root 的 sh 从空环境起步（安全评审 M1）。调用者环境里的 `BASH_FUNC_*`（bash 导入的函数）、`SHELLOPTS` 之类会穿过
    /// `do shell script` 进入 `/bin/sh`——本 session 实测 `BASH_FUNC_echo%%` 能改写结果行；脚本开头的 PATH 复位挡不住它们。
    static let shellInvocation = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /bin/sh -c "

    static let appleScriptLines = [
        "on run argv",
        "do shell script \"\(shellInvocation)\" & quoted form of (item 1 of argv) & \" cof-update \""
            + " & quoted form of (item 2 of argv) & \" \" & quoted form of (item 3 of argv)"
            + " & \" \" & quoted form of (item 4 of argv) & \" \" & quoted form of (item 5 of argv)"
            + " & \" \" & quoted form of (item 6 of argv) & \" \" & quoted form of (item 7 of argv)"
            + " & \" \" & quoted form of (item 8 of argv)"
            + " with prompt (item 9 of argv) with administrator privileges",
        "end run",
    ]

    public static func osascriptArguments(
        packagePath: String,
        digest: SHA256Digest,
        ownerUID: UInt32,
        nonce: UUID,
        waitSeconds: Int,
        target: RuntimeVersion,
        prompt: String
    ) -> [String] {
        appleScriptLines.flatMap { ["-e", $0] } + [
            rootScript, "install", packagePath, digest.hex, String(ownerUID),
            nonce.uuidString, String(waitSeconds), target.description, prompt,
        ]
    }

    // MARK: - 结果解析（AD8）

    public static func outcome(exitCode: Int32, stdout: String, stderr: String) -> PrivilegedJobOutcome {
        guard exitCode == 0 else {
            // 非 0 只剩两种：用户取消，或脚本没按契约结束。不从 stderr 里嗅 COF_RESULT——
            // AppleScript 会把 stderr 包进错误文本、最后附上退出码（F15），那不是契约的一部分。
            // 于是取消的唯一形态是「最后一行以 (-128) 结尾」；出现在别处的 (-128) 不算（安全评审 L5）。
            return lastLine(of: stderr).hasSuffix("(-128)") ? .cancelled : .unknown(RuntimeCommands.tail(stderr))
        }

        var result: String?
        var blockers: [String] = []
        var details: [String] = []
        for line in stdout.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            if line.hasPrefix("COF_RESULT=") { result = String(line.dropFirst("COF_RESULT=".count)) }
            if line.hasPrefix("COF_BUSY=") { blockers.append(String(line.dropFirst("COF_BUSY=".count))) }
            if line.hasPrefix("COF_DETAIL=") { details.append(String(line.dropFirst("COF_DETAIL=".count))) }
        }
        guard let result, let parsed = PrivilegedJobResult(rawValue: result) else {
            return .unknown(RuntimeCommands.tail(stdout))
        }
        return .finished(parsed, blockers: blockers, details: details)
    }

    /// 最后一个非空白行（`\r\n` 在 Swift 里是**一个** Character，按 `isNewline` 切才切得开）。
    private static func lastLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) } ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    public static func parseStateFile(_ text: String) -> PrivilegedJobStateFile? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        switch fields["phase"] {
        case "ready": return .ready
        case "done": return .done(fields["result"].flatMap(PrivilegedJobResult.init(rawValue:)))
        default: return nil
        }
    }

    // MARK: - lsof 判定（AD7）

    /// 对 `lsof -nP -w -d txt -F Din` 的每条映射：名字 ∈ 保护路径（①，含 rename 替换后名字不变的情形）、
    /// `D:i` ∈ 保护文件的 inode（②，硬链接）、名字 == `/` + 保护可执行文件的 basename（③，执行中被删除，F22-A）——
    /// 任一成立就打印它（命中即「仍在跑」，三条都只会偏保守）。
    static let busyAwkProgram = #"""
    BEGIN {
        while ((getline line < paths) > 0) P[line] = 1
        while ((getline line < inodes) > 0) I[line] = 1
        while ((getline line < bases) > 0) B[line] = 1
    }
    function flush() {
        if (name != "" || dev != "") {
            key = dev ":" ino
            if ((name in P) || (key in I) || (name in B)) print (name != "" ? name : key)
        }
        name = ""; dev = ""; ino = ""
    }
    /^[pf]/ { flush(); next }
    /^D/ { dev = substr($0, 2); next }
    /^i/ { ino = substr($0, 2); next }
    /^n/ { name = substr($0, 2); next }
    END { flush() }
    """#

    // MARK: - root 脚本

    public static let rootScript = [
        preamble, validation, lockSection, verification, packageIdentity,
        protectedSet, busyFunctions, verifyOnlyExit, waitSection, installSegment,
    ].joined(separator: "\n")

    /// 大写 UUID 的逐位 `case` 模式。不用 `echo | grep -x`（安全评审 L1）：grep 按行匹配，带换行的参数第一行合法就放行。
    static let uuidPattern = [8, 4, 4, 4, 12]
        .map { String(repeating: "[0-9A-F]", count: $0) }
        .joined(separator: "-")

    /// 环境复位、常量、收尾函数。可预期结局一律经 `finish`（写状态文件 + stdout 结果行 + exit 0）；
    /// 意外失败由 `set -e` 兜底，EXIT trap 把状态文件写成 `error`（被信号打断则 `interrupted`）。
    /// `CONTROL_PID`：lsof 的正控制（L3）——root 必须看得见 launchd（pid 1）；非特权身份（仅 smoke）只看得见自己。
    /// **所有 `COF_*` 行一律 `printf '%s'`**（R2）：macOS 的 `/bin/sh` 里 `echo` 会解释反斜杠转义，lsof 转义过的换行会被还原成真换行，
    /// 阻塞者的名字就能伪造出额外的协议行。cleanup 里的 `rm` 失败不许把 `finish` 已定的 exit 0 翻成 1（EXIT trap 跑在 `set -e` 下）。
    static let preamble = #"""
    set -eu
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    LC_ALL=C
    export LC_ALL
    IFS='
    	 '
    umask 077

    TEAM=\#(PackageSignature.teamID)
    RUNDIR=\#(stateDirectory)
    WORKROOT=\#(workDirectory)
    LOCK=$RUNDIR/cof-runtime-update.lock
    INSTALLER=/usr/sbin/installer
    ME=$(/usr/bin/id -u)
    if [ "$ME" -eq 0 ]; then CONTROL_PID=1; else CONTROL_PID=$$; fi
    STATE=
    WORK=
    FINISHED=0
    SIGNALLED=0

    write_state() {
        tmp=$(/usr/bin/mktemp "$RUNDIR/cof-runtime-update.tmp.XXXXXX")
        printf '%s\n' "$@" > "$tmp"
        /bin/chmod 0644 "$tmp"
        /bin/mv -f "$tmp" "$STATE"
    }

    finish() {
        if [ -n "$STATE" ]; then write_state "phase=done" "result=$1"; fi
        FINISHED=1
        printf 'COF_RESULT=%s\n' "$1"
        exit 0
    }

    cleanup() {
        if [ -n "$WORK" ]; then /bin/rm -rf "$WORK" || :; fi
        if [ -n "$STATE" ] && [ "$FINISHED" -eq 0 ]; then
            if [ "$SIGNALLED" -eq 1 ]; then
                write_state "phase=done" "result=interrupted" || :
            else
                write_state "phase=done" "result=error" || :
            fi
        fi
    }
    trap cleanup EXIT
    trap 'SIGNALLED=1; exit 130' INT TERM HUP

    is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    """#

    /// 参数形状（root 侧不信 App 传来的任何东西）。全部用 `case` 的整串匹配——换行混不过去（L1）。
    /// TARGET = 恰好三段、每段非空的纯数字版本号（M2）。数字不许前导零（R2）：`[ -ge ]` 按十进制判、`$((…))` 按八进制算，
    /// `09` 会过校验、却在写完 ready 之后才让算术报错退出（运行时已被停下）。
    static let validation = #"""
    [ "$#" -eq 7 ] || finish bad-args
    MODE=$1; PKG=$2; SHA=$3; OWNER=$4; NONCE=$5; WAIT=$6; TARGET=$7
    case "$MODE" in install|verify-only) ;; *) finish bad-args ;; esac
    case "$SHA" in ''|*[!0-9a-f]*) finish bad-args ;; esac
    [ "${#SHA}" -eq 64 ] || finish bad-args
    is_uint "$OWNER" || finish bad-args
    case "$OWNER" in 0?*) finish bad-args ;; esac
    [ "${#OWNER}" -le 10 ] || finish bad-args
    is_uint "$WAIT" || finish bad-args
    case "$WAIT" in 0*) finish bad-args ;; esac
    [ "${#WAIT}" -le 3 ] || finish bad-args
    [ "$WAIT" -ge 1 ] && [ "$WAIT" -le 600 ] || finish bad-args
    [ "${#NONCE}" -eq 36 ] || finish bad-args
    case "$NONCE" in \#(uuidPattern)) ;; *) finish bad-args ;; esac
    case "$TARGET" in ''|*[!0-9.]*|.*|*.|*..*|*.*.*.*) finish bad-args ;; *.*.*) ;; *) finish bad-args ;; esac
    [ "${#TARGET}" -le 32 ] || finish bad-args
    case "$PKG" in /*) ;; *) finish bad-args ;; esac
    """#

    /// 全局互斥（AD4）：fd 形式持锁——锁属于打开的文件描述，由 shell 与 installer 子进程共同持有（F19-B、F23-④）。
    /// 目录 `RUNDIR` 先验明正身（R2）：是符号链接 / 不是目录 / 属主不是本身份 / mode 不是 755（group、other 可写）→ busy；
    /// 不存在就以 0755 新建，建完再复核一遍。它的父目录只有 root 能写，于是这之后目录里的一切都只有 root 能动。
    /// 锁文件显式 0644，用户侧才能打开探测（F23-③）。锁路径是符号链接就拒绝，建文件用 noclobber、chmod 不跟随链接
    /// （安全评审 INFO；目录迁走后这三道是纵深，有测试守着）。
    /// 拿到锁 ⇒ 没有活着的旧任务 ⇒ 按严格文件名清掉旧状态文件（N8），再清掉被 SIGKILL 留下的 root 工作目录（INFO：每个 118 MB+）——
    /// `find` 默认不跟随符号链接，`-type d -user $ME` 只认本身份建的真目录（`/private/var/tmp` 是 sticky，别人改不了它们的名字）。
    static let lockSection = #"""
    if [ "$MODE" = install ]; then
        if [ -L "$RUNDIR" ] || { [ -e "$RUNDIR" ] && [ ! -d "$RUNDIR" ]; }; then
            printf 'COF_DETAIL=%s\n' rundir-not-directory; finish busy
        fi
        if [ ! -e "$RUNDIR" ]; then /bin/mkdir -m 0755 "$RUNDIR" 2>/dev/null || :; fi
        rundir=$(/usr/bin/stat -f '%u %Lp' "$RUNDIR" 2>/dev/null || echo missing)
        if [ -L "$RUNDIR" ] || [ "$rundir" != "$ME 755" ]; then
            printf 'COF_DETAIL=rundir-unsafe=%s\n' "$rundir"; finish busy
        fi
        if [ -L "$LOCK" ]; then printf 'COF_DETAIL=%s\n' lock-is-symlink; finish busy; fi
        if [ ! -e "$LOCK" ]; then (set -C; umask 022; : > "$LOCK") 2>/dev/null || :; fi
        /bin/chmod -h 0644 "$LOCK" 2>/dev/null || :
        if ! (: < "$LOCK") 2>/dev/null; then printf 'COF_DETAIL=%s\n' lock-open-failed; finish busy; fi
        exec 9< "$LOCK"
        /usr/bin/lockf -s -t 0 9 || finish busy
        for old in "$RUNDIR"/cof-runtime-update.*; do
            case "${old##*/}" in
                cof-runtime-update.\#(uuidPattern)|cof-runtime-update.tmp.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9])
                    if [ -f "$old" ] && [ ! -L "$old" ]; then /bin/rm -f "$old"; fi ;;
            esac
        done
        /usr/bin/find "$WORKROOT" -maxdepth 1 -type d -user "$ME" -name 'cof-runtime-update.??????' -exec /bin/rm -rf {} + 2>/dev/null || :
    fi
    """#

    /// 源文件检查 → root 私有副本 → digest 与签名复验。**与 `PackageSignature` 同一契约**（常量直接插进来，改一边另一边跟着变）。
    /// 属主检查是尽力而为：检查与拷贝之间，同一 UID 可以把文件换掉。真正的保证是**此后只信副本**——`cp -P` 不跟随符号链接
    /// （换成链接只会拷出一个链接），拷完再确认副本是普通文件（安全评审 L2）。残余：换成 FIFO 会让 cp 阻塞（DoS，不防）。
    /// digest 用 `/sbin/sha256`（C 程序；`shasum` 是 perl 脚本，受 PERL5OPT 一类环境影响——M1）。
    static let verification = #"""
    if [ ! -f "$PKG" ] || [ -L "$PKG" ]; then finish bad-source; fi
    owner=$(/usr/bin/stat -f %u "$PKG" 2>/dev/null || echo none)
    [ "$owner" = "$OWNER" ] || finish bad-source
    WORK=$(/usr/bin/mktemp -d "$WORKROOT/cof-runtime-update.XXXXXX")
    if ! /bin/cp -X -P "$PKG" "$WORK/update.pkg" 2>/dev/null; then finish bad-source; fi
    if [ ! -f "$WORK/update.pkg" ] || [ -L "$WORK/update.pkg" ]; then finish bad-source; fi

    if ! /sbin/sha256 -q "$WORK/update.pkg" > "$WORK/sha" 2>/dev/null; then finish digest-mismatch; fi
    got=$(/bin/cat "$WORK/sha")
    [ "$got" = "$SHA" ] || finish digest-mismatch

    if /usr/sbin/pkgutil --check-signature "$WORK/update.pkg" > "$WORK/sig" 2>&1; then sigrc=0; else sigrc=$?; fi
    /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WORK/sig" > "$WORK/sig.lines"
    if [ "$sigrc" -ne 0 ] || ! /usr/bin/grep -Fxq '\#(PackageSignature.statusLine)' "$WORK/sig.lines"; then
        finish signature-invalid
    fi
    /usr/bin/grep -Fxq '\#(PackageSignature.notarizationLine)' "$WORK/sig.lines" || finish signer-untrusted
    leaf=$(/usr/bin/grep -m 1 '^1\. ' "$WORK/sig.lines" || :)
    case "$leaf" in "\#(PackageSignature.leafPrefix)"*" ($TEAM)") ;; *) finish signer-untrusted ;; esac
    """#

    /// 包的身份（安全评审 M2）：签名只证明「是 Apple 签的某个包」，不证明「是这次要装的那个版本」。
    /// 从已验签的副本里取 `PackageInfo`，其 `<pkg-info …>` 起始标签必须同时带 ` identifier="…container-installer"` 与
    /// ` version="$TARGET"`（1.4.1 包实测即此二值；前导空格让 `format-version` 之类不会误中）。
    static let packageIdentity = #"""
    /bin/mkdir "$WORK/info"
    if ! /usr/bin/xar -xf "$WORK/update.pkg" -C "$WORK/info" PackageInfo > /dev/null 2>&1; then finish unexpected-version; fi
    if [ ! -f "$WORK/info/PackageInfo" ] || [ -L "$WORK/info/PackageInfo" ]; then finish unexpected-version; fi
    /usr/bin/tr '\n\r\t' '   ' < "$WORK/info/PackageInfo" > "$WORK/info.flat"
    pkginfo=$(/usr/bin/sed -n 's/.*\(<pkg-info [^>]*>\).*/\1/p' "$WORK/info.flat")
    case "$pkginfo" in *' identifier="\#(packageIdentifier)"'*) ;; *) finish unexpected-version ;; esac
    case "$pkginfo" in *" version=\"$TARGET\""*) ;; *) finish unexpected-version ;; esac
    """#

    /// 保护集合（AD7）：本包 payload ∪ 已装 receipt 的路径（前缀 /usr/local，F20）、其现有 inode、`*/bin/*` 下非 .sh 的 basename。
    static let protectedSet = #"""
    if ! /usr/sbin/pkgutil --payload-files "$WORK/update.pkg" > "$WORK/payload" 2>/dev/null; then finish unexpected-payload; fi
    /usr/bin/grep -Fxq './bin/container-apiserver' "$WORK/payload" || finish unexpected-payload
    /usr/sbin/pkgutil --files \#(packageIdentifier) > "$WORK/receipt" 2>/dev/null || : > "$WORK/receipt"
    /usr/bin/sed -n 's#^\./\(..*\)$#/usr/local/\1#p' "$WORK/payload" > "$WORK/paths"
    /usr/bin/sed -n 's#^\([^/.].*\)$#/usr/local/\1#p' "$WORK/receipt" >> "$WORK/paths"
    : > "$WORK/inodes"
    while IFS= read -r path; do
        if [ -f "$path" ]; then /usr/bin/stat -f '%#Xd:%i' "$path" >> "$WORK/inodes" 2>/dev/null || :; fi
    done < "$WORK/paths"
    /usr/bin/grep '/bin/[^/]*$' "$WORK/paths" | /usr/bin/grep -v '\.sh$' | /usr/bin/sed 's#^.*/#/#' > "$WORK/bases" || :
    /bin/cat > "$WORK/busy.awk" <<'COFAWK'
    \#(busyAwkProgram)
    COFAWK
    """#

    /// lsof 判定函数。lsof 只有「退出码 0 **且**输出里有正控制进程」才算看清了（安全评审 L3）——
    /// 否则一律视为「仍在跑」（失败关闭），阻塞者报 `lsof-failed`。
    static let busyFunctions = #"""
    list_busy() {
        if /usr/sbin/lsof -nP -w -d txt -F Din > "$WORK/lsof" 2>/dev/null; then lrc=0; else lrc=$?; fi
        if [ "$lrc" -ne 0 ] || ! /usr/bin/grep -qx "p$CONTROL_PID" "$WORK/lsof"; then
            echo "lsof-failed" > "$WORK/busy"
            return 1
        fi
        /usr/bin/awk -v paths="$WORK/paths" -v inodes="$WORK/inodes" -v bases="$WORK/bases" \
            -f "$WORK/busy.awk" "$WORK/lsof" > "$WORK/busy"
    }
    report_busy() {
        /usr/bin/head -n 20 "$WORK/busy" | while IFS= read -r blocker; do printf 'COF_BUSY=%s\n' "$blocker"; done
    }
    """#

    /// `verify-only` 在这里列出当前阻塞者就结束（不碰状态目录、不装）。
    static let verifyOnlyExit = #"""
    if [ "$MODE" = verify-only ]; then
        list_busy || :
        report_busy
        finish verified
    fi
    """#

    /// 状态文件路径**在这里才赋值**（安全评审 H1 第三层）：ready 之前的任何结局——复验失败、被信号打断——
    /// 都写不出状态文件，App 那边「看到状态文件」只可能从 ready 开始。
    /// 然后等保护集合里的可执行文件全部停止（lsof 失败 = 仍在跑）。上限按**墙钟**秒数算（L4：一轮 lsof 就要 0.4–1 秒，
    /// 数轮数会把 300 秒拖成 8–12 分钟）；取时间失败由 `set -e` 兜底（写 `error`、App 走复原），不会空转。
    /// 时钟往回走（R2）也按超时失败关闭——否则回拨几小时，运行时就被停几小时（此刻 App 已经停了它）。
    static let waitSection = #"""
    STATE=$RUNDIR/cof-runtime-update.$NONCE
    write_state "phase=ready"
    start=$(/bin/date +%s)
    deadline=$((start + WAIT))
    while :; do
        if list_busy && [ ! -s "$WORK/busy" ]; then break; fi
        now=$(/bin/date +%s)
        if [ "$now" -ge "$deadline" ] || [ "$now" -lt "$start" ]; then report_busy; finish stop-timeout; fi
        /bin/sleep 1
    done
    """#

    /// installer（R4-2：受控块，失败走得到 `finish`；R3-4：done 只在 installer 返回后写）。
    /// 从 installer 开始到脚本结束，**一直**忽略可终止的信号（R2）：之后只剩一次 lsof + 写状态 + 输出，时长有界；
    /// 恢复 trap 会让装后收到的信号把已经装好的结果改写成 `interrupted`，而漏掉的信号（USR1 / ALRM …）会让 EXIT trap
    /// 在 installer 还活着时删掉它正在读的包。被忽略的信号对 exec 出去的 installer 同样保持忽略。
    /// 装后再查一次（N4），与装前**同构、失败关闭**（R2）：lsof 看不清（阻塞者 `lsof-failed`）或有人映射着本包文件 → `raced`，
    /// 绝不在「证明不了没有混跑」时报 `installed`。
    static let installSegment = #"""
    trap '' INT TERM HUP QUIT USR1 USR2 ALRM PIPE
    if "$INSTALLER" -pkg "$WORK/update.pkg" -target / > "$WORK/installer.log" 2>&1; then irc=0; else irc=$?; fi
    if [ "$irc" -ne 0 ]; then
        printf 'COF_DETAIL=installer-exit=%s\n' "$irc"
        finish install-failed
    fi
    if list_busy && [ ! -s "$WORK/busy" ]; then finish installed; fi
    report_busy
    finish raced
    """#
}
