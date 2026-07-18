#!/usr/bin/env bash
# Day 14 本地化校验（可脚本化的「Xcode 报告无 missing」等价物 + core key 反向核对 + 产物 lproj）。
#
# 为什么每一段都在（codex #5 #9）：
# - 三语完整：app 目录（xcstrings）每个 key 的 zh-Hans/zh-Hant/ja 都得有译文。
# - core key 反向核对：core 源码里 String(coreLocalized: "…") 的每个字面 key，
#   都必须在 core 的 zh-Hans.lproj 里有条目——哨兵只证明 bundle 接上了，
#   抓不住「某条 key 拼错 / 漏译」。
# - 产物 lproj：xcodebuild 后 app bundle 里四语 lproj 真的落地了（不是只在源码）。
#
# 用法：Scripts/check-localization.sh          # 源码级检查（快）
#       Scripts/check-localization.sh --built  # 追加已构建 app bundle 的 lproj 检查
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_CATALOG="$ROOT/CradleOfFilth/Localizable.xcstrings"
CORE_RES="$ROOT/Packages/ContainerCore/Sources/ContainerCore/Resources"
CORE_SRC="$ROOT/Packages/ContainerCore/Sources/ContainerCore"
LANGS=(zh-Hans zh-Hant ja)
fail=0

echo "== 1. app 目录（xcstrings）三语完整性 =="
# 每个 key：要么有 plural variations（en 侧），要么有 stringUnit。对三语逐一验证有 translated 译文。
# 递归判据：一个 localization 命中，当它有 stringUnit.value 或 variations.plural.*.stringUnit.value。
missing=$(python3 - "$APP_CATALOG" "${LANGS[@]}" <<'PY'
import json, sys
path, *langs = sys.argv[1:]
data = json.load(open(path))
def has_value(loc):
    if "stringUnit" in loc and loc["stringUnit"].get("value") is not None:
        return True
    var = loc.get("variations", {}).get("plural", {})
    return any("stringUnit" in v and v["stringUnit"].get("value") is not None for v in var.values())
bad = []
for key, entry in data.get("strings", {}).items():
    locs = entry.get("localizations", {})
    for lang in langs:
        if lang not in locs or not has_value(locs[lang]):
            bad.append(f"{lang}\t{key}")
print("\n".join(bad))
PY
)
if [ -n "$missing" ]; then
  echo "MISSING（app 目录缺译）:"; echo "$missing"; fail=1
else
  echo "OK：app 目录三语齐全"
fi

echo "== 2. core key 反向核对（源码 String(coreLocalized: \"…\") → zh-Hans.lproj） =="
# 抽取源码里 coreLocalized 的字面 key（跨行插值统一成 %@ / %lld 的模式无法从源码直接还原，
# 故这里只核对「纯字面 key」——含插值的 key 由 zh-Hans exact 单测守，双保险）。
zh_strings="$CORE_RES/zh-Hans.lproj/Localizable.strings"
core_missing=0
while IFS= read -r key; do
  [ -z "$key" ] && continue
  # .strings 里以 "key" = "..."; 形式存在
  if ! grep -qF "\"$key\"" "$zh_strings"; then
    echo "  MISSING core zh-Hans key: $key"; core_missing=1
  fi
done < <(grep -rhoE 'coreLocalized: "[^"\\]*"' "$CORE_SRC" | sed -E 's/coreLocalized: "(.*)"/\1/' | sort -u)
if [ "$core_missing" -eq 0 ]; then echo "OK：core 纯字面 key 全部在 zh-Hans.lproj"; else fail=1; fi

echo "== 2b. core 跨 lproj key-set 等值（zh-Hans == zh-Hant == ja） =="
# codex/altitude 抓到的洞：§2 只反查 zh-Hans，core 的 zh-Hant/ja 完整性此前无自动守卫——
# 新增插值 key 漏译某语言会静默 key 回显，绕过脚本与单测（exact 测试只断言 en/zh-Hans）。
# 跨 lproj key-set 等值对「一种语言译了、忘了另一种」一网打尽（含插值 key，无需还原源码）。
# keys_of 落到临时文件，两侧走完全相同的提取路径 → 消除尾行换行歧义（否则 diff 会把
# 「最后一行没有换行符」误报成 key 集合不一致）。
keys_of() { grep -oE '^"([^"\\]|\\.)*"' "$1" 2>/dev/null | sort -u; }
base_lang="zh-Hans"
setmismatch=0
base_tmp="$(mktemp)"; keys_of "$CORE_RES/$base_lang.lproj/Localizable.strings" > "$base_tmp"
for lang in zh-Hant ja; do
  lang_tmp="$(mktemp)"; keys_of "$CORE_RES/$lang.lproj/Localizable.strings" > "$lang_tmp"
  diffout="$(diff "$base_tmp" "$lang_tmp" || true)"
  rm -f "$lang_tmp"
  if [ -n "$diffout" ]; then
    echo "  KEY-SET MISMATCH $lang vs $base_lang:"; echo "$diffout" | sed 's/^/    /'; setmismatch=1
  fi
done
rm -f "$base_tmp"
if [ "$setmismatch" -eq 0 ]; then echo "OK：core zh-Hans/zh-Hant/ja key 集合一致"; else fail=1; fi

echo "== 3. core 四语 lproj 存在 =="
for lang in en "${LANGS[@]}"; do
  if [ -d "$CORE_RES/$lang.lproj" ]; then echo "  OK $lang.lproj"; else echo "  MISSING $lang.lproj"; fail=1; fi
done

echo "== 4. plist 语法（stringsdict） =="
find "$CORE_RES" -name "*.stringsdict" -print0 | while IFS= read -r -d '' f; do
  plutil -lint "$f" >/dev/null && echo "  OK $(basename "$(dirname "$f")")/$(basename "$f")"
done

if [ "${1:-}" = "--built" ]; then
  echo "== 5. 已构建 app bundle 的四语 lproj（--built） =="
  APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*Build/Products/Debug/*.app" -maxdepth 8 -type d 2>/dev/null | grep -iv Index.noindex | head -1)
  if [ -z "$APP" ]; then echo "  未找到已构建 app（先 xcodebuild build）"; fail=1; else
    for lang in en "${LANGS[@]}"; do
      if [ -d "$APP/Contents/Resources/$lang.lproj" ]; then echo "  OK app/$lang.lproj"; else echo "  MISSING app/$lang.lproj"; fail=1; fi
    done
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILED"; fi
exit "$fail"
