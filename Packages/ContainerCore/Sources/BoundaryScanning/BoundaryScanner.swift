import Foundation

/// D1/D2 两条不变式的源码扫描规则。
///
/// **为什么单独成文件、且是纯函数**：上一版把扫描逻辑埋在 `D1BoundaryTests` 的私有 helper 里，
/// 于是「它扫得准吗」这个问题没有任何答案。而扫描器一旦漏扫，D1/D2 的测试就**恒绿**——
/// 看起来在守，其实什么都没守，是最坏的一种测试。
///
/// 抽成纯函数（源码字符串 → 违规行）之后，就能喂合成的越界样本、断言它**会红**
/// （见 `BoundaryScannerTests`）。守卫本身有了守卫。
///
/// ## 为什么住在 `Sources/BoundaryScanning/` 而不是某个测试 target 里
///
/// 它现在有**两个** package 的消费者：`ContainerCoreTests`（守「零上游依赖」）与
/// `ContainerRuntimeTests`（守「上游类型只出现在 4 个文件」）。复制一份过去，两份规则必然漂——
/// 而扫描器一旦漂了，它守的不变式就**恒绿**：看起来在守，其实什么都没守。
///
/// 它是**独立 target**（`BoundaryScanning`），产品 target 不依赖它 → 不进 app 二进制。
/// 代价是：它的源码里含 import 样例与 `.reveal()` 的正则字面量，被自己扫到就是假阳性。
/// → 两个 package 的边界测试都只扫**产品 target 的目录**（`Sources/ContainerCore/` /
/// `Sources/ContainerRuntime/`），不扫整个 `Sources/`。
///
/// ## 能力边界（别把它当成比实际更强的保障）
///
/// 这是**文本启发式，不是证明**。它没有 Swift 语法树，只有正则。review 的多轮深挖已经证明：
/// 每补一个形态，总还能再翻出一个更边角的。所以它的定位是——
///
/// - **拦得住「不小心」**：顺手加个 import、随手 log 一个明文。这是真实的、高频的风险。
/// - **拦不住「蓄意规避」**：真想绕的人有的是办法（宏、字符串拼出来的 selector……），
///   何况他直接改白名单更省事。
///
/// 所以它的价值不在密不透风，而在**让越界必须是一个显式的、留痕的动作**。
/// 别指望它替代 review；它是让 review 有东西可看。
public enum BoundaryScanner {

    public struct Violation: Equatable {
        public let line: Int
        public let text: String
        public let detail: String

        public init(line: Int, text: String, detail: String) {
            self.line = line
            self.text = text
            self.detail = detail
        }
    }

    // MARK: - D1：上游 import 不得渗透

    /// 规则：**一行里出现独立词 `import`，且其后出现上游模块名 → 命中。**
    /// 中间夹什么一概不问。
    ///
    /// 这条规则是被三轮 review 逼出来的。先前的写法是「枚举合法前缀」的白名单正则——
    /// 而 Swift 的 import 语法面比想象中宽得多，每轮 review 都能再翻出一种没枚举到的：
    ///
    /// - `import struct ContainerAPIClient.Snapshot`（import kind：只引入单个类型，
    ///   源码里**根本不出现** `import ContainerAPIClient` 这个子串）
    /// - `@_spi(Private) import ContainerAPIClient`（属性**带括号参数**）
    /// - `public import ContainerAPIClient` / `package import ...`（Swift 6 的 access-level import）
    ///
    /// 每漏一种，D1 就有一条静默的越界通道，**而测试是绿的**。枚举白名单是**失败开放**的，
    /// 而 Swift 还会继续加语法——追不完。所以反转成失败关闭：不认前缀，只认「import + 模块名」。
    /// 将来任何新语法自动被覆盖。
    ///
    /// 代价是注释或字符串里写出 `import ContainerAPIClient` 会被误报。这是**刻意的**：
    /// 误报会立刻被看见并改掉，漏报永远不会。方向不对称，就往安全那边偏。
    /// （行首注释除外——那太常见了，见下面的 `isComment`。）
    ///
    /// 「独立词」用 `(?:^|[^A-Za-z0-9_])` + negative lookahead 表达，两个坑都绕开了：
    ///
    /// - **不用 `\b`**：Swift Regex 的 `\b` 走 Unicode 词边界（UTS#29），其中 `.` 是 MidNumLet
    ///   ——`ContainerAPIClient.Snap` 在它眼里是**一个词**，字母与 `.` 之间没有边界，
    ///   于是 `\b` 在 `import struct X.Y` 上恒不匹配。实测确认过，别改回去。
    /// - **不用 lookbehind**：Swift Regex 直接报 `lookbehind is not currently supported`（实测）。
    public static func importPattern(module: String) -> Regex<AnyRegexOutput> {
        let escaped = NSRegularExpression.escapedPattern(for: module)
        let pattern = wordBoundaryFragment("import")   // 独立词 import
            + ".*[^A-Za-z0-9_]"                         // 属性 / kind / access 修饰符，不问
            + "\(escaped)(?![A-Za-z0-9_])"              // 独立词 模块名（前面那段 .*[^...] 已经
                                                         // 保证了恰好一个非词字符打底，不能再套
                                                         // 一层 wordBoundaryFragment——那会要求
                                                         // 两个非词字符连在一起，"import Foo" 这种
                                                         // 单空格间隔会直接匹配不上，详见下方说明）

        // 模式是编译期常量：构造失败只可能是这个函数写错了——属于程序员错误，不该静默降级。
        return try! Regex(pattern)
    }

    /// `importPattern`/`identifierPattern` 共用的「独立词」片段：`token` 前面必须是行首或
    /// 非词字符，后面不能紧跟另一个词字符。**只在 `token` 独立成句、前后都没有别的字符
    /// 挤占「非词字符」名额时才能直接套用**——`importPattern` 的模块名那段前面已经有
    /// `.*[^A-Za-z0-9_]` 占掉了唯一的非词字符，若在那里再套一层 `wordBoundaryFragment`，
    /// 会变成要求两个连续非词字符，`import ContainerAPIClient`（只有一个空格）反而匹配不上——
    /// 所以那段维持手写，不在此收编（B2 定案：只在语义等价处共用，别为了共用改行为）。
    private static func wordBoundaryFragment(_ token: String) -> String {
        "(?:^|[^A-Za-z0-9_])\(token)(?![A-Za-z0-9_])"
    }

    /// **只**豁免 `//` 开头的行——行注释确实吃到行尾，整行都不是代码。
    ///
    /// 刻意不豁免 `/*` 与块注释续行的 `*`：`/* 备注 */ import ContainerAPIClient` 里
    /// `*/` 之后是**活代码**，按前缀丢掉整行就等于放它过去（D1 被破坏而测试全绿）。
    /// 块注释里提到上游模块名会被误报——那是能一眼看见并改掉的，漏报不是。
    ///
    /// 行尾注释（`let x = 1  // import ContainerAPIClient`）同样不豁免：那正是藏东西的地方。
    public static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// 源码里所有越界的上游 import（行号从 1 起）。
    public static func upstreamImports(in source: String, modules: [String]) -> [Violation] {
        let patterns = modules.map { (module: $0, regex: importPattern(module: $0)) }

        return source.numberedLines.compactMap { number, line in
            guard !isComment(line) else { return nil }
            guard let hit = patterns.first(where: { line.firstMatch(of: $0.regex) != nil }) else {
                return nil
            }
            return Violation(line: number, text: line, detail: "import \(hit.module)")
        }
    }

    // MARK: - D-B'：某个类型只准被登记过的文件引用（比如「裸 LogLine 唯一消费者是 LogTailer」）

    /// `identifier` 作为**独立词**出现（不含它作为另一个更长标识符子串的情形）。
    ///
    /// 复用 `importPattern` 的独立词判定手法（不用 `\b`：Swift Regex 的 `\b` 走 UTS#29，
    /// `.`/`_` 会被算进同一个词，`Foo.Bar` 因此摸不到边界；也不用 lookbehind：
    /// Swift Regex 直接报 `lookbehind is not currently supported`，两条都是实测踩过的坑）。
    ///
    /// 「不含子串情形」是免费的，不用额外逻辑：`(?:^|[^A-Za-z0-9_])` 要求 `identifier`
    /// 前面是非词字符或行首——`RedactedLogLine` 里 `LogLine` 前面是字母 `d`，天然摸不到边界。
    public static func identifierPattern(_ identifier: String) -> Regex<AnyRegexOutput> {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        let pattern = wordBoundaryFragment(escaped)

        // 模式是编译期常量：构造失败只可能是这个函数写错了，属程序员错误，不该静默降级。
        return try! Regex(pattern)
    }

    /// 源码里所有独立词形态的 `identifier` 引用（行号从 1 起，跳过整行注释）。
    ///
    /// 同一行出现多次**分别计数**（同 `revealCallSites` 的道理：数量本身就是审计的一部分，
    /// 用 `firstMatch` 只数「有没有」会让「已经登记过一次的行里再多塞一个引用」变得不可见）。
    public static func identifierUsages(in source: String, identifier: String) -> [Violation] {
        let pattern = identifierPattern(identifier)

        return source.numberedLines.flatMap { number, line -> [Violation] in
            guard !isComment(line) else { return [] }
            return line.matches(of: pattern).map { _ in
                Violation(line: number, text: line, detail: "references \(identifier)")
            }
        }
    }

    // MARK: - D2：明文出口必须登记

    /// 源码里所有 `.reveal()` 调用点（行号从 1 起）。
    ///
    /// **刻意不判断「它流向了哪里」。** 上一版扫的是「同一行里既有 `.reveal()` 又有 `logger`」——
    /// 那是在猜泄漏的形状，而形状有无穷多种：跨行的 `logger.info("""…""")`、
    /// `let plain = s.reveal()` 之后隔十行再 log、先拼进别的 `String` 再传出去……
    /// 每补一种写法下一种就绕过去，而**绕过的时候测试是绿的**。
    ///
    /// 改成：`Sources/` 下**任何**明文出口都必须在预算里登记。不猜去向，只锁数量。
    /// 明文出口本来就该屈指可数，登记这个动作本身就是审计点。
    ///
    /// 既然规则变成了「数数」，数就必须数准——用子串 `contains` 数会在两处失准，
    /// 而两处都让预算校验**该红时保持绿**：
    ///
    /// - Swift 允许空参数列表里有空白：`secret.reveal( )` 是合法调用，子串匹配不到。
    /// - 一行里可以有多个出口：`(a.reveal(), b.reveal())` 是两个，子串只数出一个——
    ///   于是往已登记的那一行**再塞一个** reveal，预算不变，审计静默失效。
    public static func revealCallSites(in source: String) -> [Violation] {
        // `.` `reveal` `(` `)` 之间的空白都合法。
        let call = try! Regex("\\.[ \t]*reveal[ \t]*\\([ \t]*\\)")

        return source.numberedLines.flatMap { number, line in
            line.matches(of: call).map { _ in
                Violation(line: number, text: line, detail: "plaintext escape")
            }
        }
    }

    // MARK: - D2：不可信上游文本不得以 `.public` 记入日志

    /// `marker`（承载不可信上游文本的符号，如 `privateDetail`）**自己的** `privacy:` 标注若是
    /// `.public` → 命中。
    ///
    /// **为什么需要它**：`OSLogSupervisorLog` 是覆盖率豁免的薄壳（真 `os.Logger` 后端没法在单测里
    /// 断言），而「被豁免的那一层最容易藏 P1」。这里能藏的 P1 只有一种——把 `RuntimeError` 的
    /// `reason`/`path`（可能含用户名 / 项目名，甚至将来上游塞进的 env）写成 `.public`。
    /// spy 测试只能证明「记了结构化的 error」，证明不了 `os.Logger` 插值的隐私标注；这条规则补上。
    ///
    /// **不能简单地「同行含 marker 且含 `.public`」**：一条 `os.Logger` 语句常常一行里既有安全字段
    /// （id / generation，`.public` 是对的）又有不可信 detail（`.private`）——那样会把合法的行误报。
    /// 规则因此**把 marker 和它自己的隐私标注配对**：marker 之后遇到的**第一个** `privacy:` 必须不是
    /// `.public`。中间不跨过任何别的 `privacy:`（negative lookahead），于是前面那些安全字段的
    /// `.public` 与本判断无关。
    ///
    /// 与 `revealCallSites` 同理，是文本启发式：拦得住「顺手把 detail 改成 .public」，
    /// 拦不住蓄意规避（换个变量名承载文本）。价值在让「把不可信文本公开」成为显式留痕的动作。
    public static func publicPrivacyLeaks(in source: String, markers: [String]) -> [Violation] {
        let regexes = markers.map { marker -> Regex<AnyRegexOutput> in
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            // marker …（不跨过下一个 privacy:）… 第一个 privacy: 必须是 .public 才命中。
            // 编译期常量：构造失败 = 这里写错了，属程序员错误，不静默降级。
            return try! Regex("\(escaped)(?:(?!privacy:).)*?privacy:[ \t]*\\.public")
        }

        return source.numberedLines.compactMap { number, line in
            guard !isComment(line) else { return nil }
            guard regexes.contains(where: { line.firstMatch(of: $0) != nil }) else { return nil }
            return Violation(line: number, text: line, detail: "untrusted text logged as .public")
        }
    }

    // MARK: - 源码收集

    public struct SourceFile {
        /// 相对被扫目录的路径。白名单/预算表里写的就是这个。
        public let relativePath: String
        public let contents: String
    }

    /// 递归收集一个目录下的全部 `.swift`。
    ///
    /// **扫到 0 个文件必须是错误，不是「干净」。** 路径推导一旦失效（改目录、改 target 名），
    /// 「没有违规」和「没有检查」在结果上长得一模一样——而后者会让上面两条规则永远绿。
    /// 这是这个函数唯一会抛的原因。
    public static func swiftSources(under root: URL) throws -> [SourceFile] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ScanError.unreadableRoot(root.path)
        }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        let sources = try walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                SourceFile(
                    relativePath: url.path.replacingOccurrences(of: prefix, with: ""),
                    contents: try String(contentsOf: url, encoding: .utf8)
                )
            }

        guard !sources.isEmpty else { throw ScanError.noSourcesFound(root.path) }

        return sources
    }

    public enum ScanError: Error, Equatable {
        case unreadableRoot(String)
        case noSourcesFound(String)
    }
}

private extension String {
    /// 按行切分并附上 1 起的行号。保留空行，行号才与编辑器一致。
    var numberedLines: [(Int, String)] {
        split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }
}
