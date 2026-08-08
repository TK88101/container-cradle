#!/bin/bash
# UI 回调的隔离契约守卫。
#
# 为什么需要它（不是洁癖，是实测出来的洞）：
#   `@MainActor` 标注和 `Binding(set:)` 的字面闭包是**两件正交的事**。
#   实测：把 ContainerRow.onToggleManaged 的 @MainActor 删掉、字面闭包留着
#   → 编译**零警告零错误**，515+134 条测试全绿。
#   也就是说，**丢掉隔离保证是静默的**——没有任何现成机制会喊。
#   所以这条契约必须有一个专门的守卫，否则它活不过下一次重构。
#
# 三段：
#   段 1  标注在位（6 处）——删了不报警，只能显式数
#   段 2  F6 结构守卫——禁止那两种会让 Swift 6.3.3 IRGen 崩溃的写法复现
#   段 3  compile-fail fixture——正/负控制，证明 @MainActor 真的在拒绝非法调用
#
# 详见 Docs/plans/2026-08-07-sendable-isolation-fix.md。
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
red() { echo "  FAIL $*"; fail=1; }
ok()  { echo "  OK   $*"; }

# 剥注释。**只剥 `//` 是不够的**（codex Phase 3 R1）：块注释里的声明会造成假绿——
#     /*
#     let onToggleManaged: @MainActor (Bool) -> Void
#     */
# 属性其实已经被改坏，段 1 却照样通过。反向也一样：注释里的「别这么写」反例会让段 2 假红
# （第一版就是这么当场自打脸的）。所以两段都必须先过这个 lexer。
# 不处理字符串字面量里的 "//"——本仓库的属性声明与 Binding 调用里没有这种东西。
strip_comments() {
    awk '
    {
        line = $0; out = ""; i = 1
        while (i <= length(line)) {
            rest = substr(line, i)
            if (inblock) {
                p = index(rest, "*/")
                if (p == 0) { i = length(line) + 1 }
                else { i = i + p + 1; inblock = 0 }
            } else {
                p = index(rest, "/*"); q = index(rest, "//")
                if (q > 0 && (p == 0 || q < p)) { out = out substr(rest, 1, q - 1); i = length(line) + 1 }
                else if (p > 0) { out = out substr(rest, 1, p - 1); i = i + p + 1; inblock = 1 }
                else { out = out rest; i = length(line) + 1 }
            }
        }
        print out
    }' "$1"
}

echo "== 1. UI 回调的 @MainActor 标注在位 =="
# 删标注不会报警，只能这样数。
check_annotated() {   # $1=文件 $2=属性名
    local f="$1" name="$2"
    # ★ 这是**格式契约**，不是 AST 级的隔离语意检查（codex Phase 3 R2，采纳其批评）。
    #   它要求标注 inline 拼写在声明那一行。等价但不同拼法（typealias 别名、声明换行）
    #   同样把隔离写进了类型，本脚本却会判红。这是刻意的取舍：为 6 个已知属性建一个
    #   SwiftSyntax 工具，成本不成比例。**若将来真要改成 typealias，请一并改这里，别绕过。**
    if strip_comments "$f" | grep -qE "(let|var)[[:space:]]+${name}:[[:space:]]*(\(@MainActor[[:space:]]|@MainActor[[:space:]]|@escaping[[:space:]]+@MainActor[[:space:]])"; then
        ok "$name [$f]"
    else
        red "$name [$f] — 缺 @MainActor。删标注是静默的（不报警不报错），这一行就是唯一的哨兵"
    fi
}
check_annotated CradleOfFilth/MenuBar/ContainerRow.swift            onToggleManaged
check_annotated CradleOfFilth/MenuBar/ContainerRow.swift            onShowDetail
check_annotated CradleOfFilth/MenuBar/SupervisorSection.swift       onForceReconcile
check_annotated CradleOfFilth/Components/TypedConfirmationSheet.swift onConfirm
check_annotated CradleOfFilth/Components/TypedConfirmationSheet.swift onCancel
check_annotated Packages/ContainerCore/Sources/ContainerCore/Stores/LogWindowStore.swift currentGeneration
check_annotated CradleOfFilth/MenuBar/StaleWhitelistSection.swift   onRemove

# ★★ 这份清单是**硬编码**的：新增一个跨 UI 边界的回调属性，必须手动加进来，
#    否则它的标注被将来某次重构删掉时**没有任何东西会喊**——而丢标注是完全静默的
#    （零警告、零错误、全部测试绿，Day 18 实测过）。
#    `onRemove` 就是活证据：它是 Day 19 新增的，本该一并加在这里，直到发版前跑闸门
#    才发现漏了——**守卫只守它知道的那些**。
#    → 「靠记得」是这份守卫已知的洞。自动发现要 AST 分析，codex 已论证成本不成比例
#      （R2：为几个已知属性建 SwiftSyntax 工具不划算），所以洞留着，但**写在这里让人看见**。
#      加新回调时请连同这段注释一起读。

echo
echo "== 2. F6 结构守卫：禁止会让 Swift 6.3.3 IRGen 崩溃的写法 =="
# 实测：源类型在**类型层面显式携带 @MainActor** 再转 @isolated(any) @Sendable
# → thunk @$sSbScA_pSgIeAghyg_SbIeAghn_TR 的 IRGen 崩溃（signal 6，BUILD FAILED）。
# 两种触发写法都要拦：① 直传具名函数值 ② 字面闭包上显式标 @MainActor。
#
# ★ 扫描前必须剥掉注释行。第一版没剥，当场自己撞上一条假红：
#   本仓库的注释里就写着这两种反例写法（作为「别这么写」的例子），grep 一视同仁地命中了。
#   与 P1-D 那轮「ICON_TOKEN 子串匹配撞上 store.deleteImage(image)」同族。
#   **假红和假绿一样致命：假绿被人相信，假红被人绕过。**
#
# ★ 禁止类规则要按**最宽**的等价写法拦（codex Phase 3 R3）。第一版只拦
#   `set: onToggleManaged)` 和同一行的 `set: { @MainActor`，这几种等价写法能溜过去、
#   把编译器崩溃重新引进来：`set: self.onToggleManaged`、`set :`（冒号前有空格）、
#   `set:` 与实参分处两行。→ 剥注释后**折叠成一行**再扫，并允许 `self.` 与冒号两侧空白。
ROW=CradleOfFilth/MenuBar/ContainerRow.swift
ROW_FLAT=$(strip_comments "$ROW" | tr '\n' ' ')

if echo "$ROW_FLAT" | grep -qE "set[[:space:]]*:[[:space:]]*(self[[:space:]]*\.[[:space:]]*)?onToggleManaged[[:space:]]*[,)]"; then
    red "$ROW — 'set: onToggleManaged' 直传具名 @MainActor 函数值会让编译器崩溃（F6）。写成 set: { onToggleManaged(\$0) }"
else
    ok "未出现 'set: onToggleManaged' 直传"
fi
if echo "$ROW_FLAT" | grep -qE "set[[:space:]]*:[[:space:]]*\{[[:space:]]*@MainActor"; then
    red "$ROW — 'set: { @MainActor … }' 显式标注字面闭包同样会崩（F6，实验 D 实测）。去掉显式标注，让编译器推断"
else
    ok "set: 的字面闭包未显式标注 @MainActor（隔离靠推断，SE-0431 保证转 @isolated(any) 时动态保留）"
fi

echo
echo "== 3. 工具链语义 smoke test：@MainActor 在本编译器上确实会拒绝非法调用 =="
# ★ 定位修正（codex Phase 3 R4，采纳其批评）：这一段用的是**新造的独立类型** `Holder`，
#   所以它证明的是「@MainActor 这个语言特性在当前工具链上有拒绝能力」，
#   **不是**「本仓库那 6 处声明此刻仍带着标注」。后者由段 1 守（而段 1 是 grep，
#   有 R2 记录的格式契约局限）。
#   → 别把本段全绿读成「目标 2 已达成」：完整证据 = 段 1（标注在位）+ 段 3（标注有效力）。
#     两段各守一半，缺一不可。
#
# ★ 刻意不测「@MainActor 函数值直传 @isolated(any)」——那不是可断言的诊断，是编译器崩溃，
#   拿 abort 当断言对象既不稳定、又会在编译器修好后变成假红。F6 由段 2 + clean build 守。
# ★ swiftc -typecheck 测不到 F6（F6 崩在 IRGen，-typecheck 在那之前就停）——
#   两道防线互补，不是重叠。别以为本段全绿就代表这块没问题。
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT

cat > "$FX/negative.swift" <<'SWIFT'
struct Holder {
    let callback: @MainActor (Bool) -> Void
}
// 非隔离的同步上下文里同步直接调用 —— 必须被拒
func syncCallerFromNonisolated(_ h: Holder) {
    h.callback(true)
}
SWIFT

cat > "$FX/positive.swift" <<'SWIFT'
struct Holder {
    let callback: @MainActor (Bool) -> Void
}
// 跨 actor 但显式 await —— 合法的 actor hop，必须通过
func asyncCallerFromNonisolated(_ h: Holder) async {
    await h.callback(true)
}
// MainActor 上的同步调用 —— 必须通过
@MainActor
func syncCallerOnMainActor(_ h: Holder) {
    h.callback(true)
}
SWIFT

SWIFTC=(xcrun swiftc -swift-version 6 -typecheck)

if "${SWIFTC[@]}" "$FX/negative.swift" > "$FX/neg.log" 2>&1; then
    red "负控制通过了编译 —— @MainActor 没有在拒绝非隔离同步调用，目标 2 未达成"
else
    if grep -qiE "main actor|mainactor" "$FX/neg.log"; then
        ok "负控制被拒，且诊断确实指向 MainActor 隔离"
    else
        red "负控制被拒了，但诊断里没有 MainActor 字样 —— 可能是别的编译错误，这条断言不算数"
        sed 's/^/       /' "$FX/neg.log" | head -5
    fi
fi

if "${SWIFTC[@]}" "$FX/positive.swift" > "$FX/pos.log" 2>&1; then
    ok "正控制通过 —— 守卫不是无脑报错（await 的跨 actor 调用、MainActor 上的同步调用都放行）"
else
    red "正控制没通过 —— 守卫在错杀合法写法"
    sed 's/^/       /' "$FX/pos.log" | head -5
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILED"; fi
exit "$fail"
