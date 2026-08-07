#!/usr/bin/env bash
# 可访问名称的**静态防退化守卫**（2026-08-04 建；2026-08-05 按 Plan §8.4/§8.5 扩规则并修 6 条缺陷）。
#
# ## 它守什么，不守什么（边界写在最前面，别越界解读）
#
# 守两条**源码结构约束**：
#   段 1  「**空 label 的控件构造**（三种形态），必须配一个无条件、单参、非空的
#          `.accessibilityLabel(…)`，且这个修饰符挂在**同一条 fluent chain** 上」
#   段 1b 「**每一个 `TextField` / `SecureField`**，无条件要求同样合格的 `.accessibilityLabel`」
# 外加 18 个按文件 + 控件类型 / SF Symbol / helper 名锚定的定点检查（覆盖 Plan §8.3 的 21 处控件）。
#
# **不守**「App 控件都有正确名称」——差得远。反例就在本仓库：
# `CreateContainerWindowView.imageMenu` 根本没有空 literal label，
# 却拿到了 SF Symbol 的默认名 "Go Down"（描述箭头方向，不是描述动作，语义完全错）。
# 静态扫描看不见 AX 树上实际生效的名字，也看不见系统给的默认名。
# 那一类只能靠真机 AX 审计取证（Plan T5 的 `axaudit` before/after）。
# **本脚本绿 ≠ 界面可用**。把它的保证吹大一格，下一个 P1 就从那道缝里进来。
#
# ## 为什么需要它（这个缺陷是怎么活下来的）
#
# app target 没有测试 target（CLAUDE.md 明载），`ContainerRow` / 各 Window 里的
# 纯 UI 结构**零自动化覆盖**。P1-D 本身就是这么活到 v0.3.0 发版前的：
# `Toggle("", isOn:)` + `.labelsHidden()` + `.help(...)` 编译绿、跑起来也「看着正常」，
# 读屏念出来却是「复选框，未选中」——念不出它是什么，更念不出它属于哪个容器。
# 而它恰恰是**白名单开关**，本 App 存在理由的入口。
#
# 真机 AX 审计能发现它，但审计是**人工、一次性**的；把「结构别退化」这一半固化成脚本，
# 下次有人再写一个裸的 `Toggle("", …)`，CI 当场红，不必等到下一轮人工审计。
#
# ## ★ 段 1b 为什么是**无条件**要求，而不是「空 label 才要求」
#
# Plan T0 的真机实测（§8.1）：**`Form` 决定 TextField 有没有可访问名称**——
# 同一个 initializer、同一句 `.labelsHidden()`，放进 `Form` 里就有名（macOS 把标签
# 关联到控件），放进普通 `VStack`/`HStack` 里就**完全无名**。父容器一换，行为整个反过来。
# 静态扫描判不出「我的祖先里有没有 Form」（那要跨文件跨 `@ViewBuilder` 做视图树推断），
# 所以这里一律要求显式 label——Form 内多一个显式 label 无副作用，而漏一个就是无名控件。
#
# 更直接的理由：`TextField("Search", text:)` 的 title 在 macOS 上是 **placeholder**，
# **非空却仍然无名**。段 1 的「空 literal」判据对它**完全无效**——本仓库
# `LogWindowView` 的搜索框、`ImagesWindowView` 的 pull ref 框、`TypedConfirmationSheet`
# 的删卷确认框，三个真·无名控件，段 1 一个都抓不到。这就是段 1b 存在的直接原因。
#
# ## ★ 为什么预处理必须保留「空 / 非空字符串」的区分
#
# `check-menubar-layout.sh` 的 `code_only()` 把所有字符串内容清空（`Text("{")` 不能污染
# 花括号计数、字符串里的 `//` 不能被当成注释）。**直接照抄它，本脚本第 1 段当场假红**：
# `Toggle("Read-only", isOn:)` 会被压成 `Toggle("")`，被误判成「空 label 控件」。
# → 这里的剥离器把**非空**内容替换成单字符 `X`、**空**的保持 `""`。
#   两个目的都达到：内容不再干扰词法，而「有没有内容」这一位信息被留了下来。
#
# ## 四段结构
#
#   段 0  自检 fail-closed：出现 `"""` 或 `#"` → **立刻 exit 1**，一行 OK 都不再输出。
#         （旧版说 fail-closed 却继续跑段 1/2 并打印大量 OK ——「注释说的和代码做的不一致」，
#           本仓库同一轮 review 里被抓到过两次，见 CLAUDE.md。现在代码与注释一致。）
#   段 1  空 label 控件（三种形态，见下）逐个解析 fluent chain。      ← 类规则
#   段 1b 全 app target 的 `TextField` / `SecureField`。               ← 类规则
#   段 1c 全 app target 的 **icon-only 控件**（label 闭包里只有图标）。 ← 类规则
#   段 2  定点锚，**找不到 → FAIL 并提示「结构变了」**，不是判绿。      ← 实例登记
#
# ## ★ 段 1c 补的是「义务的深度」这个洞（P-A1）
#
# 段 1c 之前，守卫对「谁有义务带 label」用了**两种深度**：`TextField` 拿到**类规则**
# （无条件、与文件无关、管未来），其余控件拿到的是**实例登记**（段 2 的定点锚 ＝
# 某一天存在的控件清单，管过去）。于是明天新加一个图标按钮时：
# 段 1 看不见（没有空 literal）、段 1b 看不见（不是 TextField）、段 2 没有它的锚
# —— **三层全绿**，而它的名字来自 SF Symbol 的默认描述（那串字是 Apple 的：
# 它拥有、它本地化、无稳定性承诺，且可能语义完全错，如 `chevron.down.circle` → "Go Down"）。
# **P1-D 当初就是这么活到发版前的**；只补锚点，那条路径仍然开着。
#
# 实证（2026-08-05）：往 `StatsWindowView`（**零锚点**的文件）注入一个无 label 的
# `Button { } label: { Image(systemName:) }` —— 旧版守卫 **ALL GREEN / exit=0**，
# 加了段 1c 之后当场判红；补上 label 又转绿（不是无脑报红）。
#
# ## 段 1 认的三种「空 label」形态
#
#   A  字面量：`Toggle("", isOn:)` —— 骨架里是 `Ctor("")`。正则带 `\b` 词边界：
#      不带的话 `iconButton("")` 会被 `Button\(""` 命中、`.accessibilityLabel("")` 会被
#      `Label\(""` 命中，报「不在行首，本解析器不认」，而且**补上合格的 label 也消不掉**
#      （那条分支排在链解析之前就 continue 了）＝不可消除的假红。假红和假绿一样致命：
#      假绿被人相信，假红被人绕过。
#   B  包装类型：`Toggle(LocalizedStringKey(""), isOn:)` / `Toggle(Text(verbatim: ""), …)`
#      —— 构造的**第一个 top-level 实参**整个是一个包着空字面量的壳。
#   C  trailing closure：`Toggle(isOn:) { Text("") }` —— 构造体内相对深度 0 的 `{ … }` 块
#      内容恰好只有一个 `Text("")` / `Text(verbatim: "")`。
#
#   **不认**（登记在「已知边界」，不是默默放过）：label 闭包里放的是 `Image(...)` 而非
#   `Text("")` 的形态（`LogWindowView` 的暂停 Toggle 就是），静态判不出它「有没有名字」
#   —— 那一处由段 2 的定点锚 #15 兜住。
#
# ## 段 1 / 1b 明确拒绝的假绿路径（codex 评审 C7 + Plan §8.5 G1/G2 实证指出，逐条实现）
#
#   1. `.accessibilityLabel("")`            —— 空 literal 不算数（骨架里是 `""`，非空是 `"X"`）
#   2. `.accessibilityLabel(_, isEnabled:)` —— 条件重载不算数（同时被「单参」规则拦一道）
#   3. 挂在**嵌套闭包内子视图**上的 label   —— 那是别的视图的名字
#      判据：`.accessibilityLabel` 出现处的**相对括号深度必须为 0**（相对本 chain 起点）。
#      写进 `Toggle { … }` 的 trailing label closure 里，深度是 1，不算。
#      写在前/后一个 sibling 视图上，压根不在本 chain 的行范围内，也不算。
#   4. **同链上有 `.accessibilityHidden(…)` 且实参不是字面 `false`**（§8.5 G2）
#      —— 控件被整个移出 AX 树，label 有等于没有。有 label 却判绿，是最坏的一种假绿：
#      它让人以为这一处**已经修好了**。`.accessibilityElement(children: .ignore)`
#      与无参的 `.accessibilityElement()` 一并拒（见「已知边界」里的诚实登记）。
#
# 另外拒绝：顶层三元表达式（`cond ? A : B`，条件名 = 有一半时候是别的名字）。
# → **写法提示**：确实需要随状态变名的控件（`SecretField` 的 Show/Hide），
#   把三元写进 `Text(…)` **里面**（`Text(revealed ? "Hide \(k)" : "Show \(k)")`），
#   别写在 `.accessibilityLabel(…)` 的顶层。前者深度 ≥1，本脚本放行。
#
# 解析不出的形态（括号不平衡、chain 起点不在行首、chain 到文件尾还没闭合）
# → **FAIL 并说明「本解析器不认这种形态」**，不许默默判绿。
#
# ## removeButton 锚点怎么锚（它是个共用 helper，形态会变）
#
# `removeButton` 被 mount 行与 env 行共用，加 label 参数之后仍是一个 helper
# —— 所以**不能**去 helper 内部找字面量 label（helper 自己不该知道调用方是谁）。
# 锚点判据分两种合法形态，任一成立即通过：
#
#   形态 A（label 参数版，Plan 的预期写法）四条**全部**成立才算过：
#     ① helper 体内那条 Button chain 上有合格的 `.accessibilityLabel(…)`；
#     ② 它的实参**引用了 helper 的某个形参**（不是写死的字面量）；
#     ③ **每一个调用点**都按 argument label 显式传了那个形参
#        （top-level 切开后必须有一段 `^\s*形参外部名\s*:`）；
#     ④ 被引用的那个形参**不带默认值**。
#     → ③④ 是 §8.5 G1 的修复，缺一条整套就能被绕过。实证过的绕法：
#       把签名写成 `removeButton(rowKind: String, label: Text = Text("Remove this row"), _ action:)`，
#       调用点写 `removeButton(rowKind: "mount") { … }` —— 旧版只验「圆括号非空」，
#       于是 ALL GREEN，而两行拿到**同一个写死的名字**，正是 P2-E 缺陷本身。
#     → 「引用形参」这一条同样是关键：共用 helper 里写死一句 `"Remove this row"`，
#       所有行拿到同一个名字，读屏照样分不清哪一行——那不是修复。
#
#   形态 B（调用点版）：helper 内没有 label，但**每一个调用点**的 chain 上都有合格的 label。
#
# 两种都不成立 → FAIL。找不到 `func removeButton` → FAIL（结构变了，守卫已失效）。
#
# ## 已知边界（诚实登记，别当它不存在）
#
#   - 不处理多行字符串 `"""` 与 raw string `#"…"#`（当前 app target 没有；出现了由段 0 兜底）。
#   - 字符串插值 `\(…)` 的内容被当作字符串内容丢弃：`Text("\(x)")` 在骨架里是 `"X"`，
#     即被判为「非空」。运行时 `x` 若为空串，静态层面看不出来。
#   - 插值内部若出现引号（`"\(d["k"])"`）会把引号配对算错。当前无此写法。
#   - 只认「chain 起点在行首」的写法（本仓库全部如此）。嵌在别的调用实参里的控件构造
#     → 段 1 直接 fail-closed，不猜。
#   - `.accessibilityLabel(someExpr)` 这种非字面量实参判为通过（形态 A 必须允许），
#     但**内容是否真的非空、是否随行变化，静态证不了**——那由 Plan T5 的 AX 复验负责。
#     推论：同窗多行「两两不同名」这条（Plan G2 / A5）本脚本**完全没有覆盖**。
#   - **`#if` 出现在 chain 中间会让链判定提前结束**（§8.5 G6）：骨架里 `#if DEBUG` 既非空行
#     也不以 `.` 开头，阶段 B 当场收链，写在 `#if` 之后的 `.accessibilityLabel` 看不见 → 判红。
#     方向是对的（只在某个编译配置下存在的 label，不该算这个控件「有名字」），
#     但它是**假红不是真红**，遇到时请改写法（把 label 提到 `#if` 之前），别绕过守卫。
#   - **段 1 形态 C 只认 `Text("")`**：label 闭包里放 `Image(...)`（`LogWindowView` 暂停
#     Toggle）或放变量的，静态判不出有没有名字，段 1 看不见 —— 由段 2 定点锚补。
#   - **包装类型只认「整个实参就是一层壳」**：`Toggle(LocalizedStringKey(""), …)` 认得，
#     `Toggle(someEmptyKey, …)`（空值藏在变量里）判不出，也判不出 `Text("" + "")` 这类拼接。
#   - **`.accessibilityElement(children: .ignore)` 被一并判红**，而它其实是「把容器收成一个
#     元素再给名字」的正规写法。当前 app target 零使用，所以这里选 fail-closed；
#     将来真要用它，请连同本脚本一起更新，别只是绕过。
#   - 段 2 里 `kind == 'symbol'` 的那几个锚，只认字面量写法（`Image(systemName: "…")`
#     或 `Label(…, systemImage: "…")`）；符号名来自变量的锚不了。
#     （这里刻意不写个数：CLAUDE.md 的 Day 13 勘误就是「数字写死在文档里必然陈旧」，
#     以 ANCHORS 表为唯一权威。）
#     `Image(systemName: someVar)` / `Image(systemName: a ? "x" : "y")`
#     （`LogWindowView` 暂停 Toggle、`SecretField` 复制按钮、banner）锚不了
#     —— 那几处改用「作用域内控件计数」锚。
#   - 把 `.accessibilityLabel` 挂在**计算属性的使用点**（例如在 `imageMenu` 被引用的地方挂）
#     而不是属性自身的 chain 上 → 本脚本报红。方向是 fail-closed，但那是假红，
#     真遇到请改写法或更新本脚本，别把它当成「守卫坏了」直接绕过。
#   - 段 2 的 18 个锚是照**当前结构**写死的（控件类型 / 作用域名 / SF Symbol / helper 名）。
#     重构这几个视图必然要回来改本脚本——这是刻意的：宁可逼人更新，也不要悄悄失效。
#   - 扫描范围 = `CradleOfFilth/`（app target）。`Packages/` 是 core，不含 SwiftUI 视图。
#
# ## 有牙的证据（实跑，不是推理）
#
#   否定对照：在**未加任何 label 的源码**上跑 → exit=1；段 1、段 1b、段 2 分别报红。
#   正 对照：沙盒里按 Plan §8.3 把 21 处（外加段 1b 覆盖到的另 3 个 Form 内 TextField）
#           补齐 → ALL GREEN，exit=0。
#   突变电池：M3–M14（空 literal / 条件重载 / 嵌套闭包内子视图 / sibling 视图 / 注释掉的
#   label / 多行字符串 / 共用 helper 写死字面量 / 调用点漏传实参 / 删控件 / helper 改名 /
#   换符号）＋ §8.5 的 G1–G4 各自的绕过路径（默认值形参、`accessibilityHidden(true)`、
#   trailing closure 空 label、`iconButton("")` 假红）逐条验过红/绿。
#   反向也验了：`Toggle("Read-only", …)` 与「修饰符之间夹中文注释」都**不得**误报红。
#
# 用法：Scripts/check-accessibility.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os
import re
import sys
from collections import namedtuple

ROOT = sys.argv[1]
APP_DIR = os.path.join(ROOT, 'CradleOfFilth')

# 「带 label 的控件构造」白名单。刻意不含 Image / Text：
# 它们不是可交互控件，且 Image 会把 `Image(systemName:)` 本身算成一条 chain，
# 让段 2 的「符号落在哪条 chain 里」出现二义。
CONTROL_CTORS = ('Toggle', 'Picker', 'TextField', 'SecureField',
                 'Stepper', 'Slider', 'Button', 'Menu', 'Label')
CTOR_START_RE = re.compile(r'^(?:' + '|'.join(CONTROL_CTORS) + r')\s*[({]')
# ★ `\b` 不是装饰（§8.5 G4）：没有它，`iconButton("")` 会被 `Button\(""` 命中、
# `.accessibilityLabel("")` 会被 `Label\(""` 命中，产生**补了 label 也消不掉**的假红。
EMPTY_LABEL_RE = re.compile(r'\b(?:' + '|'.join(CONTROL_CTORS) + r')\(""')
LABEL_TOKEN = '.accessibilityLabel('
HIDDEN_TOKEN = '.accessibilityHidden('
ELEMENT_TOKEN = '.accessibilityElement('

# 空 label 的两种「壳」形态（判定前先把空白全去掉，跨行写法一并归一）。
EMPTY_TEXT_RE = re.compile(r'^Text\((?:verbatim:)?""\)$')
EMPTY_WRAPPER_RE = re.compile(r'^(?:Text|LocalizedStringKey|String)\((?:verbatim:|localized:)?""\)$')

# 段 1c 用：label 闭包里「有图标」与「有文字」的判据。
# 骨架里非空字符串是 `"X"`，所以 `Text("X")` / `Text(verbatim:"X")` / `Text(k)` 都算有文字。
#
# ★ 两个都必须带 `\b`，理由与 EMPTY_LABEL_RE 的那条完全相同（§8.5 G4）：
# 不带的话 `store.deleteImage(image)` 里的 `Image(` 会命中 —— 规则刚上线就撞上了这一条，
# 把 `ImagesWindowView` 的 confirmationDialog 误报成 icon-only 控件。
# 同理 `alertText(` 之类会污染文字判据（那个方向是假红：本来有文字却被判成没有）。
ICON_RE = re.compile(r'\bImage\(')
NONEMPTY_TEXT_RE = re.compile(r'\bText\(')

TEXT_FIELD_CTORS = ('TextField', 'SecureField')

Chain = namedtuple('Chain', 'end text depths ctor_len')


def code_only(lines):
    """剥注释、压字符串内容，产出与原文**行数一一对应**的骨架（行号可直接引用）。

    与 check-menubar-layout.sh 的同名函数有两处关键差异：

    1. 非空字符串压成 `"X"`、空字符串保持 `""`。段 1 的整条规则就架在这一位信息上，
       照抄那边的「一律清空」会把 `Toggle("Read-only", …)` 误判成空 label 控件。
    2. **块注释按深度计数，不是布尔开关。** Swift 的 `/* */` **可以嵌套**，
       而布尔版遇到内层 `*/` 就认为注释结束，其后的文本被当成代码。
       实证过的假绿：把真 label 换成
       `/* outer /* inner */ .accessibilityLabel(Text("Auto-start fake")) */`
       —— 控件其实一个 label 都没有，守卫却报 ALL GREEN。
       （codex review 提出，本地突变复现坐实。`check-menubar-layout.sh` 有同一个 bug，
       但那不在本轮范围里，已登记待办。）
    """
    out, block_depth = [], 0
    for line in lines:
        res, i, in_str, has_content = [], 0, False, False
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
                    has_content, i = True, i + 2   # 跳过转义（含 \" 与 \( ）
                    continue
                if c == '"':
                    in_str = False
                    if has_content:
                        res.append('X')
                    res.append(c)
                    i += 1
                    continue
                has_content, i = True, i + 1
                continue
            if c == '"':
                in_str, has_content = True, False
                res.append(c)
                i += 1
                continue
            if c == '/' and nxt == '/':
                break                              # 行注释：丢弃本行剩余（含行尾注释）
            if c == '/' and nxt == '*':
                block_depth, i = block_depth + 1, i + 2
                continue
            res.append(c)
            i += 1
        out.append(''.join(res))
    return out


class SwiftFile:
    def __init__(self, path):
        self.path = path
        self.rel = os.path.relpath(path, ROOT)
        self.raw = open(path, encoding='utf-8').read().splitlines()
        self.src = code_only(self.raw)


def chain_at(src, line, col):
    """从 (line, col) 解析一整条 fluent chain（0-based 行号）。

    返回 `Chain`；解析不出返回 None（调用方一律 fail-closed）。
    `depths[i]` 是 `text[i]` 相对 chain 起点的括号/花括号深度——段 1 判「这个修饰符
    到底挂在谁身上」全靠它：深度 0 = 挂在本 chain，深度 ≥1 = 在某个闭包里的子视图上。
    `ctor_len` 是**构造本体**（不含后续修饰符）在 `text` 里的长度——段 1 的形态 B/C
    只在构造本体里找，免得把 `.overlay { Text("") }` 之类的修饰符当成 label 闭包。

    两阶段：A 吃构造本体（到深度回 0 的**行尾**为止——`} label: {` 这种一行内先关后开
    的写法，只看行尾才不会被切断）；B 继续吃后续以 `.` 开头的修饰符行，
    每个修饰符同样吃到深度回 0，于是跨行写的 `.accessibilityLabel(\n Text(…)\n)` 也完整。

    ★ 阶段 B 必须**跨过骨架里的空行**（＝注释行与真空行）再判断链有没有断。
    本仓库的写法是每个非显然的修饰符上面压一句中文「为什么」注释——
    `.labelsHidden()` / 注释 / `.accessibilityLabel(…)` 是**最可能出现的正确写法**。
    若在注释处就判定链结束，守卫会对着一份**改对了的代码**报红。
    假红和假绿一样会让守卫失去信用：假绿被人相信，假红被人绕过。
    """
    text, depths, depth = [], [], 0

    def eat(segment):
        nonlocal depth
        for ch in segment:
            if ch in '([{':
                depths.append(depth)
                depth += 1
            elif ch in ')]}':
                depth -= 1
                depths.append(depth)
            else:
                depths.append(depth)
            text.append(ch)
        text.append('\n')
        depths.append(depth)
        return depth >= 0

    i, cur_col, closed = line, col, False
    while i < len(src):
        if not eat(src[i][cur_col:]):
            return None                             # 深度变负 = 词法已经错位，不猜
        cur_col = 0
        if depth == 0:
            closed = True
            break
        i += 1
    if not closed:
        return None                                 # 到文件尾还没闭合
    end = i
    ctor_len = len(text)

    j = end + 1
    while j < len(src):
        k = j
        while k < len(src) and not src[k].strip():
            k += 1                                  # 跨过注释行 / 空行（骨架里都是空串）
        if k >= len(src) or not src[k].strip().startswith('.'):
            break                                   # 下一个非空行不是修饰符 → 链到此为止
        m = k
        while m < len(src):
            if not eat(src[m]):
                return None
            if depth == 0:
                break
            m += 1
        else:
            return None
        end = m
        j = m + 1
    return Chain(end, ''.join(text), depths, ctor_len)


def ctor_of(src_line):
    """这一行是不是控件构造的起点；是的话返回控件名。"""
    m = CTOR_START_RE.match(src_line.lstrip())
    if not m:
        return None
    return re.match(r'\w+', m.group(0)).group(0)


def control_chains(src):
    """枚举文件里所有「以控件构造开头」的 chain。嵌套的也会各自成链——
    段 2 用「恰好一条 chain 包含锚点行」来判定归属，多于一条就是结构有二义，FAIL。"""
    out = []
    for i, line in enumerate(src):
        s = line.lstrip()
        if not CTOR_START_RE.match(s):
            continue
        parsed = chain_at(src, i, len(line) - len(s))
        out.append((i, parsed))
    return out


def balanced_arg(text, open_idx):
    """从 `(` 处取出配平的实参文本。括号不平衡返回 None（fail-closed）。"""
    depth = 0
    for i in range(open_idx, len(text)):
        c = text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
    return None


def balanced_block(text, open_idx, limit=None):
    """从 `{` 处取出配平的闭包体，返回 (体文本, 闭合处下标)。不平衡返回 (None, -1)。"""
    end = len(text) if limit is None else limit
    depth = 0
    for i in range(open_idx, end):
        c = text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], i
    return None, -1


def top_level_split(arg):
    parts, depth, cur = [], 0, []
    for c in arg:
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        if c == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
            continue
        cur.append(c)
    parts.append(''.join(cur))
    return parts


def has_top_level_ternary(arg):
    depth, seen_q = 0, False
    for c in arg:
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif depth == 0 and c == '?':
            seen_q = True
        elif depth == 0 and c == ':' and seen_q:
            return True
    return False


def squash(s):
    """去掉全部空白（含换行）——跨行写的 `Text(\n  verbatim: ""\n)` 归一成一种形状。"""
    return ''.join(s.split())


def classify_label(arg):
    """给一个 `.accessibilityLabel(…)` 的实参定性。返回 (是否合格, 原因)。"""
    if arg is None:
        return False, '实参括号不平衡，本解析器不认这种形态（fail-closed）'
    if len(top_level_split(arg)) > 1:
        return False, '多参重载（如 isEnabled:）——不是无条件的名称，不算'
    if re.search(r'\bisEnabled\s*:', arg):
        return False, '条件重载 isEnabled: ——不算'
    if has_top_level_ternary(arg):
        return False, '顶层三元表达式——有一半时候是别的名字，不算（要随状态变名请把三元写进 Text(…) 里面）'
    stripped = arg.strip()
    if not stripped:
        return False, '空实参'
    literals = re.findall(r'"(X?)"', arg)
    # `not all` 而不是 `not any`：任一支为空就判红。
    # 头部把「三元写进 Text(…) 里面」列为推荐写法（要随状态变名只能这么写），
    # 于是 `Text(cond ? "" : "x")` 恰好落在这一格——有一半时候控件无名，
    # 而 `not any` 只要有一支非空就放行，推荐写法正好绕过检查。
    if literals and not all(literals):
        return False, '含空 literal（如 .accessibilityLabel("") 或 Text(cond ? "" : "x")）——有时候没名字，不算数'
    return True, ('非空 literal' if any(literals) else '非字面量实参（内容由 T5 真机 AX 复验负责）')


def depth0_hits(text, depths, token):
    """token 在**相对深度 0**（＝挂在本 chain 上，不在任何闭包里）出现的位置。"""
    out, idx = [], 0
    while True:
        p = text.find(token, idx)
        if p < 0:
            return out
        idx = p + 1
        if depths[p] == 0:
            out.append(p)


def removed_from_ax_tree(text, depths):
    """控件是不是被同一条链上的修饰符移出了 AX 树（§8.5 G2）。返回原因，没问题返回 None。

    有 label 却被 hidden 掉，是最坏的一种假绿：它让人以为这一处**已经修好了**，
    而读屏里那个控件压根不存在。所以这条判在找 label **之前**，一票否决。
    """
    for p in depth0_hits(text, depths, HIDDEN_TOKEN):
        arg = balanced_arg(text, p + len(HIDDEN_TOKEN) - 1)
        shown = squash(arg) if arg is not None else '?'
        if shown != 'false':
            return '同链上有 .accessibilityHidden(%s)：控件被移出 AX 树，label 完全无效' % shown
    for p in depth0_hits(text, depths, ELEMENT_TOKEN):
        arg = balanced_arg(text, p + len(ELEMENT_TOKEN) - 1)
        shown = squash(arg) if arg is not None else '?'
        if shown == '' or 'children:.ignore' in shown:
            return '同链上有 .accessibilityElement(%s)：子元素被吞掉，本守卫按 fail-closed 判红' % shown
    return None


def inspect_chain(parsed):
    """在一条 chain 上找合格的 `.accessibilityLabel`。返回 (是否合格, 说明, 实参文本)。"""
    if parsed is None:
        return False, 'chain 解析不出（括号不平衡或到文件尾未闭合），本解析器不认这种形态（fail-closed）', None
    text, depths = parsed.text, parsed.depths
    removed = removed_from_ax_tree(text, depths)
    if removed:
        return False, removed, None
    reasons, idx = [], 0
    while True:
        p = text.find(LABEL_TOKEN, idx)
        if p < 0:
            break
        idx = p + 1
        if depths[p] != 0:
            reasons.append('有 .accessibilityLabel 但挂在嵌套闭包内的子视图上（相对深度 %d），不算本控件的名字' % depths[p])
            continue
        arg = balanced_arg(text, p + len(LABEL_TOKEN) - 1)
        ok, why = classify_label(arg)
        if ok:
            return True, why, arg
        reasons.append(why)
    if not reasons:
        return False, '链上没有 .accessibilityLabel', None
    return False, '；'.join(reasons), None


def ctor_first_arg(parsed):
    """构造本体的第一个 top-level 实参（没有圆括号实参返回 None）。"""
    body = parsed.text[:parsed.ctor_len]
    for i, c in enumerate(body):
        if parsed.depths[i] != 0:
            continue
        if c == '(':
            arg = balanced_arg(body, i)
            return None if arg is None else top_level_split(arg)[0]
        if c == '{':
            return None                              # 先遇到闭包 = 这个构造没有圆括号实参
    return None


def empty_label_shape(parsed):
    """构造是不是「空 label」的形态 B / C。返回说明，不是则返回 None。

    只在**构造本体**里找（`ctor_len` 之前）：`.overlay { Text("") }` 是修饰符里的子视图，
    不是这个控件的 label，混进来就是假红。
    """
    if parsed is None:
        return None
    first = ctor_first_arg(parsed)
    if first is not None and EMPTY_WRAPPER_RE.match(squash(first)):
        return '形态 B：首个实参是包着空字面量的壳 %s' % squash(first)
    body, depths, n = parsed.text, parsed.depths, parsed.ctor_len
    i = 0
    while i < n:
        if body[i] == '{' and depths[i] == 0:
            inner, close = balanced_block(body, i, n)
            if inner is None:
                break
            if EMPTY_TEXT_RE.match(squash(inner)):
                return '形态 C：label 闭包里只有一个空 %s' % squash(inner)
            i = close + 1
            continue
        i += 1
    return None


def icon_only_label_shape(parsed):
    """控件的 label 内容是不是**只有图标、没有任何文字**。是则返回说明，不是返回 None。

    ## 这条规则为什么必须存在（P-A1）

    在它之前，守卫对「义务」用了**两种深度**：`TextField` 拿到的是**类规则**
    （段 1b：无条件、与文件无关、管未来），其余控件拿到的是**实例登记**
    （段 2 的定点锚 = 某一天存在的控件清单，管过去）。
    于是新加一个图标按钮时：段 1 看不见（没有空 literal）、段 1b 看不见（不是 TextField）、
    段 2 没有它的锚 —— **三层全绿**，而它的名字来自 SF Symbol 的默认描述。
    P1-D 当初就是这么活到发版前的；只补锚点，那条路径仍然开着。

    ## 判据

    构造本体里**相对深度 0** 的 `{ … }` 块（＝这个控件自己的 label / content 闭包，
    不是修饰符里的子视图），内容含 `Image(` 且**不含任何 `Text(`** → 判为 icon-only。

    - `Button(action:) { Image(systemName:) }`、`Toggle(isOn:) { Image(…) }`、
      `Button { … } label: { Image(…) }` 全部命中。
    - `Label("文本", systemImage:)` **不**命中：它自带文字标题（那正是 imageMenu 的修法），
      不属于「拿不到任何文字来源」的情形。
    - `HStack { Image(…); Text("…") }` 不命中：有文字。
    - `Menu { 内容块 } label: { 图标块 }` 两个块都会被看一遍，任一块命中即算。

    ## 边界

    图标藏在自定义子视图里（`Button { MyIcon() }`）判不出来——静态看不见 `MyIcon` 渲染什么。
    这条规则收的是**直写 `Image(`** 的那一类，也就是本仓库现役的全部写法。
    """
    if parsed is None:
        return None
    body, depths, n = parsed.text, parsed.depths, parsed.ctor_len
    i = 0
    while i < n:
        if body[i] == '{' and depths[i] == 0:
            inner, close = balanced_block(body, i, n)
            if inner is None:
                break
            s = squash(inner)
            if ICON_RE.search(s) and not NONEMPTY_TEXT_RE.search(s):
                return '形态 D：label 闭包里只有图标（%s）' % (s[:48] + ('…' if len(s) > 48 else ''))
            i = close + 1
            continue
        i += 1
    return None


def symbol_lines(f):
    """定位真代码里的 SF Symbol 字面量，并取回符号名。

    两种写法都认：`Image(systemName: "…")` 与 `Label(…, systemImage: "…")`。
    后者不是可有可无的补充——`Menu { } label: { Image(systemName:) }` 时，SF Symbol 的默认名
    （如 chevron.down.circle → "Go Down"）会落进 **AXTitle**，与 `.accessibilityLabel` 写的
    AXDescription **摇摆着抢优先级**（真机实测：同一二进制同一窗口，两次读到不同的名字）。
    修法是改用 `Label` 让两条信道说同一句话，于是符号就从 `systemName:` 搬到了 `systemImage:`。
    只认前一种写法的话，做对了修复反而会把锚点弄丢。

    为什么要绕骨架这一圈：骨架把字符串内容压成 X，符号名没了；而直接在 raw 上找，
    一行被注释掉的 `// Image(systemName: "trash")` 就能当锚点，锚到错的 chain 上去。
    先用骨架证明「这一行是代码」，再回 raw 取字面量——两边的短板互相补上。
    """
    skeleton_re = re.compile(r'Image\(systemName:\s*"|systemImage:\s*"')
    raw_re = re.compile(r'(?:Image\(systemName:|systemImage:)\s*"([^"]*)"')
    found = {}
    for i, line in enumerate(f.src):
        if not skeleton_re.search(line):
            continue
        m = raw_re.search(f.raw[i])
        if m:
            found[i] = m.group(1)
    return found


# ---------------------------------------------------------------- 段 0：自检

paths = [os.path.join(d, n)
         for d, _, names in os.walk(APP_DIR)
         for n in names if n.endswith('.swift')]
files = sorted((SwiftFile(p) for p in paths), key=lambda f: f.rel)
fail = 0

print('== 0. 自检：本剥离器不认多行 / raw 字符串 ==')
selfcheck = 0
for f in files:
    for n, line in enumerate(f.raw, 1):
        if '"""' in line or re.search(r'#"', line):
            print('  FAIL %s:%d 出现多行 / raw 字符串 → 拒绝给出结论（fail-closed）' % (f.rel, n))
            selfcheck = 1
if not files:
    print('  FAIL 在 %s 下找不到任何 .swift —— 目录结构变了，守卫已失效，请更新本脚本' % APP_DIR)
    selfcheck = 1

# ★ 说 fail-closed 就要真的停在这里（§8.5 G5）。旧版继续往下跑、照常输出几十行 OK，
# 于是「拒绝给出结论」变成了「给出一份不可信的结论」——比不输出更糟，因为它看起来像结论。
if selfcheck:
    print()
    print('  骨架不可信 → 段 1 / 1b / 2 全部不执行（它们的判据全都架在骨架上）')
    print('FAILED')
    sys.exit(1)

print('  OK 扫描 %d 个 app target 源文件，未出现多行 / raw 字符串' % len(files))

# ------------------------------------------- 段 1：空 label 的通用规则

print()
print('== 1. 空 label 控件（形态 A 字面量 / B 包装类型 / C trailing closure）'
      '必须配无条件、单参、非空的 .accessibilityLabel ==')
hits = 0
for f in files:
    reported = set()
    # 形态 A：`Ctor("")` 字面量。
    for i, line in enumerate(f.src):
        m = EMPTY_LABEL_RE.search(line)
        if not m:
            continue
        hits += 1
        reported.add(i)
        s = line.lstrip()
        col = len(line) - len(s)
        if m.start() != col:
            # 构造点不在行首（嵌在别的实参里）→ chain 起点无从判定，不猜。
            print('  FAIL %s:%d 空 label 控件不在行首，本解析器不认这种形态（fail-closed）'
                  % (f.rel, i + 1))
            fail = 1
            continue
        ok, why, _ = inspect_chain(chain_at(f.src, i, col))
        tag = 'OK  ' if ok else 'FAIL'
        print('  %s %s:%d 形态 A：%s — %s' % (tag, f.rel, i + 1, m.group(0), why))
        if not ok:
            fail = 1
    # 形态 B / C：包装类型壳、trailing closure 里的空 Text。
    for i, parsed in control_chains(f.src):
        if i in reported:
            continue
        shape = empty_label_shape(parsed)
        if shape is None:
            continue
        hits += 1
        ok, why, _ = inspect_chain(parsed)
        tag = 'OK  ' if ok else 'FAIL'
        print('  %s %s:%d %s — %s' % (tag, f.rel, i + 1, shape, why))
        if not ok:
            fail = 1
print('  共 %d 处空 label 构造' % hits)
if hits == 0:
    print('  （0 处不代表界面没问题：空 label 只是「无名控件」的一个子集，'
          '默认名语义错的那一类静态看不见）')

# ---------------------------- 段 1b：TextField / SecureField 无条件要求 label

print()
print('== 1b. 每一个 TextField / SecureField 都必须配合格的 .accessibilityLabel'
      '（Form 决定有没有名称，静态判不出父容器 → 一律显式要求）==')
tf_hits = 0
for f in files:
    for i, parsed in control_chains(f.src):
        if ctor_of(f.src[i]) not in TEXT_FIELD_CTORS:
            continue
        tf_hits += 1
        ok, why, _ = inspect_chain(parsed)
        tag = 'OK  ' if ok else 'FAIL'
        print('  %s %s:%d %s — %s' % (tag, f.rel, i + 1, ctor_of(f.src[i]), why))
        if not ok:
            fail = 1
print('  共 %d 处 TextField / SecureField 构造' % tf_hits)
if tf_hits == 0:
    print('  FAIL 一个都没扫到 —— %s' % '结构变了，守卫已失效，请更新本脚本')
    fail = 1

# ------------------------- 段 1c：icon-only 控件无条件要求 label（P-A1 的类规则）

print()
print('== 1c. 每一个 icon-only 控件（label 闭包里只有图标、没有文字）'
      '都必须配合格的 .accessibilityLabel ==')
icon_hits = 0
for f in files:
    for i, parsed in control_chains(f.src):
        shape = icon_only_label_shape(parsed)
        if shape is None:
            continue
        icon_hits += 1
        ok, why, _ = inspect_chain(parsed)
        tag = 'OK  ' if ok else 'FAIL'
        print('  %s %s:%d %s — %s' % (tag, f.rel, i + 1, shape, why))
        if not ok:
            fail = 1
print('  共 %d 处 icon-only 控件' % icon_hits)
if icon_hits == 0:
    print('  FAIL 一个都没扫到 —— %s' % '结构变了，守卫已失效，请更新本脚本')
    fail = 1

# ------------------------------------------------------- 段 2：定点锚

# (文件, 说明, 锚类型, 参数, 作用域, 期望条数)
# 作用域 = None 表示整个文件；否则是该文件里某个 `var` / `func` 的函数体行范围
# ——`CreateContainerWindowView` 有 5 个 TextField，只有按作用域切开才锚得住是哪一行的哪一个。
ANCHORS = [
    ('CradleOfFilth/MenuBar/ContainerRow.swift',
     '#1 白名单勾选框 Toggle', 'ctor', 'Toggle', None, 1),
    ('CradleOfFilth/MenuBar/ContainerRow.swift',
     '#2 详情 Button (info.circle)', 'symbol', 'info.circle', None, 1),
    ('CradleOfFilth/Windows/CreateContainerWindowView.swift',
     '#3 mount 行 volume Picker', 'ctor', 'Picker', 'mountRowsList', 1),
    ('CradleOfFilth/Windows/CreateContainerWindowView.swift',
     '#4 mount 行 path TextField', 'ctor', 'TextField', 'mountRowsList', 1),
    ('CradleOfFilth/Windows/CreateContainerWindowView.swift',
     '#5 mount 行 Read-only Toggle', 'ctor', 'Toggle', 'mountRowsList', 1),
    ('CradleOfFilth/Windows/CreateContainerWindowView.swift',
     '#6/#9 removeButton 共用 helper（mount / env 两行共用）', 'removeButton', None, None, 0),
    ('CradleOfFilth/Windows/CreateContainerWindowView.swift',
     '#7/#8 env 行 key / value TextField', 'ctor', 'TextField', 'envRowsList', 2),
    ('CradleOfFilth/Windows/CreateContainerWindowView.swift',
     '#10 imageMenu (chevron.down.circle)', 'symbol', 'chevron.down.circle', None, 1),
    ('CradleOfFilth/Windows/ImagesWindowView.swift',
     '#11 删除镜像 Button (trash)', 'symbol', 'trash', None, 1),
    ('CradleOfFilth/Windows/ImagesWindowView.swift',
     '#12 pull ref TextField', 'ctor', 'TextField', None, 1),
    ('CradleOfFilth/Windows/VolumesWindowView.swift',
     '#13 删除 volume Button (trash)', 'symbol', 'trash', None, 1),
    ('CradleOfFilth/Windows/LogWindowView.swift',
     '#14 日志搜索框 TextField', 'ctor', 'TextField', None, 1),
    ('CradleOfFilth/Windows/LogWindowView.swift',
     '#15 暂停 / 恢复 Toggle', 'ctor', 'Toggle', None, 1),
    ('CradleOfFilth/Windows/LogWindowView.swift',
     '#16 复制全部 Button (doc.on.doc)', 'symbol', 'doc.on.doc', None, 1),
    ('CradleOfFilth/Windows/LogWindowView.swift',
     '#17 清空 Button (trash)', 'symbol', 'trash', None, 1),
    ('CradleOfFilth/Windows/LogWindowView.swift',
     '#18 重开 Button (arrow.clockwise)', 'symbol', 'arrow.clockwise', None, 1),
    ('CradleOfFilth/Components/SecretField.swift',
     '#19/#20 Show/Hide + Copy Button', 'ctor', 'Button', None, 2),
    ('CradleOfFilth/Components/TypedConfirmationSheet.swift',
     '#21 删卷确认输入 TextField', 'ctor', 'TextField', None, 1),
]

print()
print('== 2. 定点锚（%d 个，覆盖 Plan §8.3 的控件清单）==' % len(ANCHORS))

STRUCTURE_CHANGED = '结构变了，守卫已失效，请更新本脚本'
by_rel = {f.rel: f for f in files}


def report(label, rel, ok, detail):
    global fail
    print('  %s %s [%s] — %s' % ('OK  ' if ok else 'FAIL', label, rel, detail))
    if not ok:
        fail = 1


def scope_range(f, name):
    """按 `var` / `func` 名取出函数体行范围。找不到 / 有二义 → None（调用方 fail-closed）。"""
    pattern = re.compile(r'\b(?:var|func)\s+%s\b' % re.escape(name))
    defs = [i for i, l in enumerate(f.src) if pattern.search(l)]
    if len(defs) != 1:
        return None
    return helper_body_range(f.src, defs[0])


def anchor_ctor(f, ctor, scope, count):
    if scope is None:
        span, where = None, '整个文件'
    else:
        span = scope_range(f, scope)
        if span is None:
            return False, '找不到唯一的作用域 `%s` —— %s' % (scope, STRUCTURE_CHANGED)
        where = '`%s` 体（line %d–%d）' % (scope, span[0] + 1, span[1] + 1)
    starts = []
    for i, p in control_chains(f.src):
        if span is not None and not (span[0] <= i <= span[1]):
            continue
        if ctor_of(f.src[i]) == ctor:
            starts.append((i, p))
    if len(starts) != count:
        return False, '%s 里以 %s 开头的 chain 有 %d 条（期望恰好 %d 条）—— %s' % (
            where, ctor, len(starts), count, STRUCTURE_CHANGED)
    details, all_ok = [], True
    for i, parsed in starts:
        ok, why, _ = inspect_chain(parsed)
        all_ok = all_ok and ok
        details.append('line %d：%s' % (i + 1, why))
    return all_ok, '%s 里 %d 条 %s —— %s' % (where, count, ctor, '；'.join(details))


def anchor_symbol(f, symbol):
    lines = [i for i, name in symbol_lines(f).items() if name == symbol]
    if len(lines) != 1:
        return False, 'SF Symbol "%s"（systemName: 或 systemImage:）出现 %d 次（期望恰好 1 次）—— %s' % (symbol, len(lines), STRUCTURE_CHANGED)
    target = lines[0]
    owners = [(i, p) for i, p in control_chains(f.src)
              if p is not None and i <= target <= p.end]
    if not owners:
        return False, '符号在 line %d，但没有任何控件 chain 包含它 —— %s' % (target + 1, STRUCTURE_CHANGED)
    # 符号可能同时落在**嵌套的**多条 chain 里：`Menu { } label: { Label(…, systemImage:) }`
    # 的 `Label` 自己也是 CONTROL_CTORS 之一，于是 Menu 与 Label 两条都命中。
    # 拿到 AX 身份的是**最外层**那条（内层只是它的 label 内容），所以取 start 最小的。
    # 这不是放宽：判据因此**变严**——挂在内层 `Label` 上的 accessibilityLabel 不再算数。
    owners.sort(key=lambda t: t[0])
    i, parsed = owners[0]
    ok, why, _ = inspect_chain(parsed)
    return ok, 'chain @ line %d（符号在 line %d）：%s' % (i + 1, target + 1, why)


def helper_body_range(src, def_line):
    """从 `func` / `var` 定义行找出体的行范围。签名里的 `() -> Void` 不能被当成函数体开头，
    所以先把圆括号深度数到 0，第一个落在深度 0 的 `{` 才是函数体。"""
    paren, i, start = 0, def_line, None
    while i < len(src) and start is None:
        for c in src[i]:
            if c in '([':
                paren += 1
            elif c in ')]':
                paren -= 1
            elif c == '{' and paren == 0:
                start = i
                break
        if start is None:
            i += 1
    if start is None:
        return None
    depth, j = 0, start
    while j < len(src):
        depth += src[j].count('{') - src[j].count('}')
        if depth == 0 and j >= start:
            return start, j
        j += 1
    return None


def helper_params(src, def_line):
    """取 helper 的形参：外部标签 / 内部名 / **有没有默认值**。

    默认值这一位是 §8.5 G1 的关键：`label: Text = Text("Remove this row")` 让调用点
    可以整个不传，于是所有行拿到同一个写死的名字——正是 P2-E 缺陷本身，
    而旧版只验「调用点圆括号非空」，这种签名能拿到 ALL GREEN。
    """
    flat = '\n'.join(src[def_line:def_line + 20])
    open_idx = flat.find('(')
    if open_idx < 0:
        return None
    sig = balanced_arg(flat, open_idx)
    if sig is None:
        return None
    out = []
    for part in top_level_split(sig):
        m = re.match(r'\s*(?:(\w+|_)\s+)?(\w+)\s*:', part)
        if not m:
            continue
        out.append({
            'external': m.group(1),
            'internal': m.group(2),
            'has_default': _has_default(part[m.end():]),
        })
    return out


def _has_default(rest):
    """形参类型之后有没有 top-level 的 `=`。`==` / `>=` / `->` 不算。"""
    depth = 0
    for i, c in enumerate(rest):
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == '=' and depth == 0:
            prev = rest[i - 1] if i else ''
            nxt = rest[i + 1] if i + 1 < len(rest) else ''
            if prev in '=!<>' or nxt == '=':
                continue
            return True
    return False


def call_arg_text(src, line, col):
    """调用点 `removeButton` 后面紧跟的显式实参列表文本；裸 trailing closure 返回 None。

    `removeButton { … }`（加参数**之前**的写法）与
    `removeButton(label: …) { … }`（加参数**之后**）的区别就在这一位：
    有没有显式的圆括号实参。
    """
    rest = src[line][col:]
    k = 0
    while k < len(rest) and rest[k].isspace():
        k += 1
    if k >= len(rest) or rest[k] != '(':
        return None
    parsed = chain_at(src, line, col)
    if parsed is None:
        return None
    open_idx = parsed.text.find('(')
    return balanced_arg(parsed.text, open_idx) if open_idx >= 0 else None


def call_arg_labels(arg_text):
    """调用点实参列表里出现的 argument label 集合（位置实参不产生 label）。"""
    labels = set()
    for part in top_level_split(arg_text or ''):
        m = re.match(r'\s*(\w+)\s*:', part)
        if m:
            labels.add(m.group(1))
    return labels


def anchor_remove_button(f):
    src = f.src
    defs = [i for i, l in enumerate(src) if re.search(r'\bfunc\s+removeButton\b', l)]
    if len(defs) != 1:
        return False, '`func removeButton` 出现 %d 次（期望恰好 1 次）—— %s' % (len(defs), STRUCTURE_CHANGED)
    d = defs[0]
    body = helper_body_range(src, d)
    if body is None:
        return False, 'removeButton 函数体括号解析不出，本解析器不认这种形态（fail-closed）'
    b0, b1 = body
    params = helper_params(src, d)
    if params is None:
        return False, 'removeButton 签名解析不出，本解析器不认这种形态（fail-closed）'

    inner = [(i, p) for i, p in control_chains(src)
             if b0 <= i <= b1 and ctor_of(src[i]) == 'Button']
    if len(inner) != 1:
        return False, 'helper 体内 Button chain 有 %d 条（期望恰好 1 条）—— %s' % (len(inner), STRUCTURE_CHANGED)

    calls = []
    for i, line in enumerate(src):
        if b0 <= i <= b1 or (i == d):
            continue
        for m in re.finditer(r'\bremoveButton\b', line):
            calls.append((i, m.end()))
    if not calls:
        return False, '找不到任何 removeButton 调用点 —— %s' % STRUCTURE_CHANGED

    ok_inner, why_inner, arg = inspect_chain(inner[0][1])
    if ok_inner:
        # 形态 A：label 由参数传入。四条判据缺一不可，见头部注释。
        refs = [p for p in params if re.search(r'\b%s\b' % re.escape(p['internal']), arg or '')]
        if not refs:
            return False, ('helper 体内 line %d 的 .accessibilityLabel 没有引用任何形参 %s'
                           '——共用 helper 写死名称 = mount / env 各行同名，读屏仍分不清哪一行'
                           % (inner[0][0] + 1, [p['internal'] for p in params]))
        defaulted = [p['internal'] for p in refs if p['has_default']]
        if defaulted:
            return False, ('被 .accessibilityLabel 引用的形参 %s **带默认值** —— 调用点可以整个不传，'
                           '于是各行拿到同一个写死的名字（正是 P2-E 缺陷本身）。请去掉默认值'
                           % defaulted)
        positional = [p['internal'] for p in refs if p['external'] == '_']
        if positional:
            return False, ('被 .accessibilityLabel 引用的形参 %s 用了 `_` 外部标签（位置传参），'
                           '调用点无法按名核对是否真的传了它 —— 本解析器不认这种形态（fail-closed）'
                           % positional)
        expected = sorted({p['external'] or p['internal'] for p in refs})
        bad = []
        for i, col in calls:
            labels = call_arg_labels(call_arg_text(src, i, col))
            missing = [e for e in expected if e not in labels]
            if missing:
                bad.append('line %d 缺 %s' % (i + 1, missing))
        if bad:
            return False, ('helper 已按参数取名（形参 %s），但调用点没有显式传：%s'
                           % (expected, '；'.join(bad)))
        return True, ('形态 A：helper line %d 的 label 引用形参 %s（%s，无默认值）；'
                      '%d 个调用点均按 label 显式传参 %s'
                      % (inner[0][0] + 1, expected, why_inner, len(calls), [i + 1 for i, _ in calls]))

    # 形态 B：helper 不带 label，改由每个调用点自己挂。
    bad = []
    for i, col in calls:
        ok, why, _ = inspect_chain(chain_at(src, i, col - len('removeButton')))
        if not ok:
            bad.append('line %d（%s）' % (i + 1, why))
    if bad:
        return False, ('helper 内无合格 label（%s），调用点也没有补：%s'
                       % (why_inner, '；'.join(bad)))
    return True, '形态 B：helper 无 label，但 %d 个调用点各自挂了合格的 label' % len(calls)


for rel, label, kind, arg, scope, count in ANCHORS:
    f = by_rel.get(rel)
    if f is None:
        report(label, rel, False, '文件不存在 —— %s' % STRUCTURE_CHANGED)
        continue
    if kind == 'ctor':
        ok, detail = anchor_ctor(f, arg, scope, count)
    elif kind == 'symbol':
        ok, detail = anchor_symbol(f, arg)
    else:
        ok, detail = anchor_remove_button(f)
    report(label, rel, ok, detail)

print()
print('ALL GREEN' if fail == 0 else 'FAILED')
sys.exit(fail)
PY
