#!/bin/bash
# 发版警告闸门：给定 archive log 与仓库根，判定本仓库源码是否带编译警告。
#
#   用法：warning-gate.sh <archive-log> <repo-root>
#   退出码：0 = 放行（零警告）；1 = 拦截（命中行去前缀后打到 stderr）
#
# 为什么从 release.sh 里搬出来：**发版路径一年跑不了几次**，闸门若漏报，
# 要等到下一次 archive 才可能被发现——而那正是它该拦住的时刻。原地改无法在不跑
# 一次全量 archive（十几分钟）的前提下验证，那等于没验证。搬出来是为了能黑箱测。
#
# ★ 路径匹配用**字面前缀**，不用正则。
#   原实现把 $REPO 直接插进 `grep -E` 的模式串**和** `sed "s|^$REPO/||"` 的替换式。
#   前者让路径里的 `+ ( ) [ ] ^ $ \` 变成元字符；后者更糟——`|` 正是那个 sed 的分隔符。
#   逐个 escape 是在补一个不该存在的问题：路径比较本来就是字符串比较，不是模式匹配。
#   换成 index()/substr() 之后，整类问题不存在（而不是「被处理了」）。
#
# ★ 目录限制（CradleOfFilth/ 与 Packages/）不是可省的细节。
#   只判仓库前缀会把 build/、Spikes/、.build/ 里的警告也变成发布阻断。
#   「更严」在这里是回归不是加固：发版会被无关的实验代码卡住，而人对反复误报的反应
#   是绕过闸门，不是修警告。
set -euo pipefail

LOG="${1:?usage: warning-gate.sh <archive-log> <repo-root>}"
REPO="${2:?usage: warning-gate.sh <archive-log> <repo-root>}"

# ★ 用 ENVIRON 取 repo，**不能用 `awk -v`**：`-v` 的赋值会经过转义序列处理，
#   路径里的 `\i`（以及 `\n` `\t` …）在进入脚本前就被吃掉/改写了 → 比对必然失败 →
#   **有警告也放行**。这正是本文件想根除的那类洞换了个位置又长出来：
#   换成字面匹配确实消掉了「正则元字符」，但 `-v` 自己是另一层转义，两者是独立的问题。
#   ENVIRON 按原样传字节。（用例 ③ 第一次跑就是红的，抓到的就是这个。）
HITS="$(COF_GATE_REPO="$REPO" awk '
    BEGIN { repo = ENVIRON["COF_GATE_REPO"] }
    index($0, repo "/") != 1 { next }
    { rel = substr($0, length(repo) + 2) }
    index(rel, "CradleOfFilth/") != 1 && index(rel, "Packages/") != 1 { next }
    index(rel, "warning:") == 0 { next }
    { print rel }
' "$LOG" | sort -u)"

if [ -n "$HITS" ]; then
    echo "error: Release 构建带编译警告，发版中止。" >&2
    printf '%s\n' "$HITS" >&2
    exit 1
fi
exit 0
