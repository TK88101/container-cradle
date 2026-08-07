#!/usr/bin/env bash
# 菜单栏 footer 布局的**静态防退化守卫**（2026-08-03，B-0）。
#
# ## 它守什么，不守什么（边界写在最前面，别越界解读）
#
# 守的是**源码结构约束**：「管理入口不能三个平铺在同一行」。
# **不守**「界面没有截断」——那是渲染结果，静态扫描看不见，只能靠真机四语取证
# （截图目视 + AX frame，见 Docs/plans/2026-08-03-b0-layout-overflow-fix.md T1/T5）。
# 两者互补：本脚本挡住「有人又把按钮塞回一行」，取证挡住「文案变长撑破现有布局」。
# 任何一次改文案或换字体，仍然必须回去重新取证，本脚本绿不能代替那件事。
#
# ## 为什么需要它（这个 bug 是怎么活下来的）
#
# 一句话：popover 296pt 装不下三个平铺标签，SwiftUI 静默截断——不报错、不 log、编译绿。
#
# **完整数字与推导只有一份**，在 MenuBarRootView.swift 紧邻那两个 HStack 的注释里
# （搜 "两行不是排版偏好"）。这里刻意不复述预算算法与四语实测值：
# 同一份事实分居两处，下次重新取证必然只改一处、另一处悄悄漂掉
# （CLAUDE.md 已登记过这个病：「状态存两处必然漂」）。
#
# ## ★ 为什么要先剥注释和字符串（不是洁癖，是实证过的假绿路径）
#
# 第一版三段检查都在**原始文本**上匹配，codex review 指出 5 条假绿路径，实测坐实三条：
#   A. 行尾注释：`.frame(width: 360)  // was .frame(width: 320)` → 守卫报绿，宽度已被改
#   B. 块注释：  `/* .frame(width: 320) */`                      → 同上
#   C. 被注释掉的 `// 原本是 HStack(spacing: 8)`                  → 骗过第 3 段
# 更早还踩过一条：解释这条约束的**注释自己**写着 `.frame(width: 320)`，
# 于是「守卫被自己要守的那份文档骗了」。
# → 一次预处理产出 code-only 骨架（剥掉注释与字符串字面量内容），三段共享它。
#   顺带把「同一文件读三遍」合并成读一遍。
#
# 已知边界（诚实登记，别当它不存在）：
#   - 不处理多行字符串 """ 与 raw string #"..."#（本文件没有；出现了由自检 fail-closed 兜底）
#   - 深度计数只在骨架上做——字符串里的花括号已被剥掉，不再干扰
#
# 用法：Scripts/check-menubar-layout.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/CradleOfFilth/MenuBar/MenuBarRootView.swift"

python3 - "$VIEW" <<'PY'
import re, sys

path = sys.argv[1]
raw = open(path).read().splitlines()


def code_only(lines):
    """剥掉注释与字符串字面量内容，产出与原文**行数一一对应**的骨架（行号可直接引用）。

    保留引号但清空内容：这样 Text("{") 之类不会污染花括号计数，
    而 // 出现在字符串里时也不会被误当成注释开始。
    """
    # ★ 块注释按**深度计数**，不是布尔开关：Swift 的 `/* */` 可以嵌套，
    # 布尔版遇到内层 `*/` 就以为注释结束，其后的文本被当成代码。
    # 实证过的假绿（2026-08-05）：把 `.frame(width: 320)` 换成
    # `/* outer /* inner */ .frame(width: 320) */` —— 真代码里已经没有宽度约束了，
    # 第 2 段却照报 ALL GREEN。
    # 这个 bug 是在 check-accessibility.sh 里被 codex review 抓到的；两个脚本各有一份
    # code_only 副本，只修一份 = 另一份继续假绿（本 session 实时发生过一次）。
    out, block_depth = [], 0
    for line in lines:
        res, i, in_str = [], 0, False
        while i < len(line):
            c = line[i]
            nxt = line[i + 1] if i + 1 < len(line) else ''
            if block_depth:
                if c == '/' and nxt == '*':
                    block_depth, i = block_depth + 1, i + 2
                    continue
                if c == '*' and nxt == '/':
                    block_depth, i = block_depth - 1, i + 2
                    continue
                i += 1
                continue
            if in_str:
                if c == '\\':
                    i += 2                      # 跳过转义（含 \" 与 \( ）
                    continue
                if c == '"':
                    in_str = False
                    res.append(c)
                i += 1
                continue
            if c == '"':
                in_str = True
                res.append(c)
                i += 1
                continue
            if c == '/' and nxt == '/':
                break                            # 行注释：丢弃本行剩余（含行尾注释）
            if c == '/' and nxt == '*':
                block_depth, i = block_depth + 1, i + 2
                continue
            res.append(c)
            i += 1
        out.append(''.join(res))
    return out


src = code_only(raw)
fail = 0

# 自检：本剥离器不认多行/raw 字符串，遇到就 fail-closed，而不是默默算错。
for n, line in enumerate(raw, 1):
    if '"""' in line or re.search(r'#"', line):
        print(f'  FAIL line {n}: 出现多行/raw 字符串，本剥离器不支持 → 拒绝给出结论（fail-closed）')
        fail = 1

print("== 1. 管理入口每行平铺按钮数 <= 2 ==")
# 判据锚点用 openManagementWindow( 调用点，不是 Button( 字面量：
# footer 里还有 Show whitelist file / Quit 等按钮，数 Button 会把它们算进来。
# 三个管理入口是唯一调用 openManagementWindow 的地方，锚得准。
depth, stack, blocks = 0, [], []
for i, line in enumerate(src, 1):
    if re.search(r'\bHStack\s*[({]', line):
        stack.append([depth, i, 0])
    if 'openManagementWindow(' in line and 'private func' not in line and stack:
        stack[-1][2] += 1
    depth += line.count('{') - line.count('}')
    while stack and depth <= stack[-1][0]:
        _, start, count = stack.pop()
        if count:
            blocks.append((start, count))

if not blocks:
    print("  FAIL 找不到任何含 openManagementWindow 的 HStack —— 布局结构变了，守卫已失效，请更新本脚本")
    fail = 1
else:
    for start, count in blocks:
        print(f"  {'OK' if count <= 2 else 'FAIL'} HStack @ line {start}: {count} 个管理入口")
        if count > 2:
            print("  → 三个及以上平铺在同一行，en/ja 必然截断。拆行或改用 Menu 收纳。")
            fail = 1
    print(f"  管理入口总数 = {sum(c for _, c in blocks)}（分布在 {len(blocks)} 行）")

print()
print("== 2. popover 硬宽度未被改动 ==")
# 宽度一改，296pt 的预算前提就变了，必须重新做四语取证。
if any('.frame(width: 320)' in line for line in src):
    print("  OK .frame(width: 320) 仍在")
else:
    print("  FAIL popover 宽度已变（或写法已改）——296pt 预算失效，请重新四语取证并更新本脚本")
    fail = 1

print()
print("== 3. 管理入口所在 HStack 显式写了 spacing ==")
# 为什么必须显式写死 spacing：理由在 MenuBarRootView.swift 同一段注释里（不复述）。
# 这里只说本段的判据：只认**真的含管理入口**的那些 HStack，不是文件里随便哪个——
# 否则别处一个 HStack(spacing:) 就能让这段变绿（实证过的假绿路径 C）。
spacing_missing = [start for start, _ in blocks
                   if not re.search(r'HStack\(spacing:\s*[0-9]+\)', src[start - 1])]
if blocks and not spacing_missing:
    print(f"  OK {len(blocks)} 个管理入口 HStack 都写了显式 spacing")
else:
    for n in spacing_missing:
        print(f"  FAIL HStack @ line {n} 没有显式 spacing")
    fail = 1

print()
print("ALL GREEN" if fail == 0 else "FAILED")
sys.exit(fail)
PY
