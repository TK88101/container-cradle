#!/usr/bin/env bash
#
# m3-acceptance.sh —— M3 是这个项目的生死线，把它的验收从「一串手打命令」变成一条可重复的脚本。
#
# 验的是本 App 存在的唯一理由：apple/container 没有 restart policy，运行时回来容器不会自己回来——
# 而这个 App 应该在运行时换代后**自动拉起白名单容器**。
#
#   container system stop  →  container system start  →  在 TIMEOUT 内 cof-canary 自动回到 running？
#
# ★ 有副作用：`container system stop` 停的是**整个运行时 = 所有容器**。只有白名单里 enabled 的会自动
#   回来；其它（比如你的 open-connector）会留在停止态。脚本事后会**尽力重启**那些「事前在跑、现在停了」
#   的容器，把机器恢复原样——但这是 best-effort，真在用的工作负载请自己确认。
#
# 用法：
#   Scripts/m3-acceptance.sh            # 交互确认后跑
#   Scripts/m3-acceptance.sh --yes      # 跳过确认（CI / 重复回归）
#   TIMEOUT=60 Scripts/m3-acceptance.sh # 改等待上限（秒，默认 40）
#
# 退出码：0 = PASS，1 = FAIL / 前置条件不满足。

set -euo pipefail

CANARY="cof-canary"
TIMEOUT="${TIMEOUT:-40}"
WHITELIST="$HOME/Library/Application Support/CradleOfFilth/supervisor.json"
# Day 16 T10 勘误：Day 12 起 PRODUCT_NAME = "Container Cradle"，进程名随之改变
#（pgrep -x 按完整名匹配；旧值 CradleOfFilth 会让前置检查恒 FAIL）。
APP_PROCESS="Container Cradle"

# container CLI 不走 PATH（防劫持，与 CLIProcessRunner 同纪律）；找不到再退回 PATH。
CONTAINER="/usr/local/bin/container"
[ -x "$CONTAINER" ] || CONTAINER="$(command -v container || true)"

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
info()  { printf '  %s\n' "$1"; }

fail() { red "FAIL: $1"; exit 1; }

# 列出当前 running 的容器 ID（container ls 首列＝ID，不带 -a 只显示 running）。
running_ids() {
    "$CONTAINER" ls 2>/dev/null | awk 'NR>1 {print $1}'
}

is_running() {
    running_ids | grep -qx "$1"
}

# ---- 前置条件（任一不满足都判 FAIL，因为那样这条验收根本没意义）----

echo "== M3 验收：运行时换代后白名单容器自动回来 =="

[ -n "$CONTAINER" ] && [ -x "$CONTAINER" ] || fail "找不到 container CLI（/usr/local/bin/container）"

if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
    fail "CradleOfFilth 没在运行——supervisor 不在，没人会去自动拉起容器。先把 App 打开。"
fi

[ -f "$WHITELIST" ] || fail "白名单文件不存在：$WHITELIST"

# cof-canary 必须 enabled，否则 supervisor 不会碰它 → 永远不会回来 → 这条验收无意义。
# 只认「id 是 cof-canary 且同一条目 enabled: true」——用 python3 解析，不靠脆弱的 grep。
if ! python3 - "$WHITELIST" "$CANARY" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
canary = sys.argv[2]
ok = any(e.get("id") == canary and e.get("enabled") is True
         for e in data.get("entries", []))
sys.exit(0 if ok else 1)
PY
then
    fail "白名单里 $CANARY 不是 enabled=true——菜单里勾上它再跑（否则 supervisor 不会自动拉它）。"
fi

if ! is_running "$CANARY"; then
    fail "$CANARY 现在就不是 running——请先让它起来（这是被停→自动回来的靶子）。"
fi

# ---- 记录事前在跑的容器，供事后恢复 ----

BEFORE_RUNNING="$(running_ids)"
info "事前在跑：$(echo "$BEFORE_RUNNING" | tr '\n' ' ')"

# ---- 确认（有副作用：停整个运行时）----

if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    red "这会执行 container system stop —— 停掉整个运行时（所有容器）。"
    info "只有白名单里 enabled 的会自动回来；其它容器脚本会尽力重启。"
    printf "继续？输入 yes 确认："
    read -r reply
    [ "$reply" = "yes" ] || { echo "已取消。"; exit 1; }
fi

# ---- 恢复钩子：无论成败，把事前在跑、现在停了的容器尽力拉回来 ----

restore() {
    echo
    echo "== 恢复：把事前在跑、现在停了的容器拉回来（best-effort）=="
    # 先确保运行时在（可能停在失败路径上）。
    "$CONTAINER" system start >/dev/null 2>&1 || true
    for cid in $BEFORE_RUNNING; do
        if ! is_running "$cid"; then
            info "重启 $cid …"
            "$CONTAINER" start "$cid" >/dev/null 2>&1 || info "  （$cid 重启失败，请手动检查）"
        fi
    done
}
trap restore EXIT

# ---- 执行：停 → 起 → 等 canary 自动回来 ----

echo
echo "== 停运行时 =="
"$CONTAINER" system stop
# 等运行时真的下去（container ls 开始报错 / 空）。
for _ in $(seq 1 10); do is_running "$CANARY" || break; sleep 1; done

echo "== 起运行时 =="
"$CONTAINER" system start

echo "== 等 $CANARY 自动回来（上限 ${TIMEOUT}s，全程不手动 start）=="
start=$SECONDS
deadline=$((start + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
    if is_running "$CANARY"; then
        green "PASS：$CANARY 在 $((SECONDS - start))s 内自动回到 running。"
        exit 0
    fi
    sleep 2
done

fail "$CANARY 在 ${TIMEOUT}s 内没有自动回来——supervisor 没能补上「运行时回来」这个洞。查 log stream（subsystem com.cradleoffilth.supervisor）。"
