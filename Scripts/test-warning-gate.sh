#!/bin/bash
# `warning-gate.sh` 的测试。8 类用例，覆盖 codex 两轮评审抓到的全部形态。
#
# 为什么闸门值得单独有测试：它住在发版路径上，而**发版路径一年跑不了几次**——
# 漏报（有警告却放行）要等到下一次 archive 才可能被发现，而那正是它该拦住的时刻。
# 原地改 `release.sh` 无法在不跑一次全量 archive（十几分钟）的前提下验证，那等于没验证。
#
# 用例 ③⑤⑥⑦⑧ 全部来自 codex 评审：
#   ③ 元字符（C7）      ⑤ 前缀相近（index==1 的边界）
#   ⑥ 目录限制（复审 D3，我改写时引入的真 bug）
#   ⑦⑧ 两种 symlink（复审 D2）
set -uo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
GATE="$HERE/warning-gate.sh"

fail=0
ok()  { echo "  [ok]   $1"; }
red() { echo "  [FAIL] $1"; fail=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cof-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mklog() {
    local name="$1"; shift
    local path="$WORK/$name.log"
    printf '%s\n' "$@" > "$path"
    echo "$path"
}

expect_pass() {
    local desc="$1" log="$2" repo="$3"
    if "$GATE" "$log" "$repo" > "$WORK/out" 2>&1; then
        ok "$desc"
    else
        red "$desc —— 闸门拦截了，但本应放行"
        sed 's/^/         /' "$WORK/out" | head -5
    fi
}

expect_block() {
    local desc="$1" log="$2" repo="$3" expect_rel="$4"
    if "$GATE" "$log" "$repo" > "$WORK/out" 2>&1; then
        red "$desc —— 闸门放行了，但本应拦截"
    elif grep -qF "$expect_rel" "$WORK/out"; then
        ok "$desc"
    else
        red "$desc —— 拦住了，但输出里没有期望的相对路径 '$expect_rel'"
        sed 's/^/         /' "$WORK/out" | head -5
    fi
}

echo "== warning-gate.sh =="

REPO1="/Users/x/Repo"

# ① 干净 log
LOG1=$(mklog clean \
    "Build settings from command line:" \
    "    ARCHS = arm64" \
    "** ARCHIVE SUCCEEDED **")
expect_pass "① 干净 log → 放行" "$LOG1" "$REPO1"

# ② 本仓库源码 warning
LOG2=$(mklog dirty \
    "$REPO1/CradleOfFilth/AppModel.swift:42:9: warning: unused variable 'x'" \
    "** ARCHIVE SUCCEEDED **")
expect_block "② 本仓库 warning → 拦截" "$LOG2" "$REPO1" "CradleOfFilth/AppModel.swift"

# ③ ★ repo 路径含完整 regex 元字符集（C7）。用 regex 拼接的实现在这里必然漏报或错位。
REPO3='/Users/x/a+b(c)|d[e]f^g$h\i'
LOG3=$(mklog metachar \
    "$REPO3/Packages/ContainerCore/Sources/Foo.swift:7:1: warning: deprecated API" \
    "** ARCHIVE SUCCEEDED **")
expect_block "③ repo 含元字符 → 仍正确拦截" "$LOG3" "$REPO3" "Packages/ContainerCore/Sources/Foo.swift"

# ④ 工具链噪音（非本仓库路径）
LOG4=$(mklog toolchain \
    "/Applications/Xcode.app/Contents/Developer/usr/bin/appintentsmetadataprocessor: warning: metadata extraction skipped" \
    "/Library/Developer/SDKs/MacOSX.sdk/Foo.h:1:1: warning: something upstream")
expect_pass "④ 仅工具链噪音 → 放行" "$LOG4" "$REPO1"

# ⑤ ★ 前缀相近但不同的仓库：repo=/Users/x/Repo 时 /Users/x/Repo-other/… 不算命中
LOG5=$(mklog sibling \
    "/Users/x/Repo-other/CradleOfFilth/Other.swift:1:1: warning: not ours")
expect_pass "⑤ 前缀相近的兄弟目录 → 不误伤" "$LOG5" "$REPO1"

# ⑥ ★ 仓库内、但不是源码目录（复审 D3）。原闸门只数 CradleOfFilth/ 与 Packages/；
#    丢掉目录限制会把 build//Spikes/ 里的 warning 变成发布阻断——比原闸门更严，是回归。
LOG6=$(mklog nonsource \
    "$REPO1/build/release/generated.swift:3:1: warning: generated code smell" \
    "$REPO1/Spikes/f6-isolation-matrix/probe.swift:1:1: warning: experiment")
expect_pass "⑥ 仓库内非源码目录（build/ Spikes/）→ 放行" "$LOG6" "$REPO1"

LOG6b=$(mklog packages \
    "$REPO1/Packages/ContainerRuntime/Sources/Bar.swift:1:1: warning: x")
expect_block "⑥b Packages/ 也在闸门范围内" "$LOG6b" "$REPO1" "Packages/ContainerRuntime/Sources/Bar.swift"

echo
echo "== release.sh 的仓库根解析（两种 symlink，复审 D2）=="

# release.sh 需要 canonical 的 REPO：xcodebuild 输出真实路径，
# REPO 若停在 symlink 路径上，闸门比对的两边根本对不上 → 静默漏报。
REAL_REPO="$(cd -P "$HERE/.." && pwd)"

probe_repo() {  # release.sh 的诊断子命令：打印 REPO 后退出，不跑 archive
    "$1" --print-repo-root 2>/dev/null
}

# ⑦ 目录 symlink：symlink 指向仓库根，经它调用 Scripts/release.sh
DIRLINK="$WORK/repo-dirlink"
ln -s "$REAL_REPO" "$DIRLINK"
got=$(probe_repo "$DIRLINK/Scripts/release.sh")
if [ "$got" = "$REAL_REPO" ]; then
    ok "⑦ 目录 symlink 调用 → REPO 解析为真实路径"
else
    red "⑦ 目录 symlink：期望 '$REAL_REPO'，实得 '$got'"
fi

# ⑧ ★ 脚本文件自身是 symlink —— `cd -P "$(dirname "$0")/.."` 单独解决不了这一种：
#    dirname 指向 symlink 所在目录，-P 只解析那个目录，到不了仓库。
FILELINK="$WORK/release-filelink.sh"
ln -s "$REAL_REPO/Scripts/release.sh" "$FILELINK"
got=$(probe_repo "$FILELINK")
if [ "$got" = "$REAL_REPO" ]; then
    ok "⑧ 脚本自身 symlink 调用 → REPO 解析为真实路径"
else
    red "⑧ 脚本自身 symlink：期望 '$REAL_REPO'，实得 '$got'"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILED"; exit 1; fi
