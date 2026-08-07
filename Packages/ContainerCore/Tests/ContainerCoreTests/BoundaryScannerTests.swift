import BoundaryScanning
import Testing

/// 守卫的守卫。
///
/// `D1BoundaryTests` 现在是绿的——但那证明不了任何事，除非先证明**它在该红的时候会红**。
/// 一个漏扫的扫描器产出的绿灯比没有测试更危险：它把「没人检查」伪装成「检查通过」。
///
/// 下面每个「必须抓到」的样本，都是 review 实证能绕过上一版字面量扫描的写法。
@Suite("边界扫描器：该红的时候必须红")
struct BoundaryScannerTests {

    static let upstreamModules = ["ContainerAPIClient", "Containerization"]

    // MARK: - D1：上游 import

    /// 上一版用 `contents.contains("import ContainerAPIClient")` 字面量匹配。
    /// 下面除第一条外，**每一条都不含那个子串**，却全都真实引入了上游类型——
    /// 也就是说 D1 被破坏时，上一版的测试是绿的。
    @Test(
        "抓得到各种形态的上游 import",
        arguments: [
            "import ContainerAPIClient",
            "import  ContainerAPIClient",                          // 多空格
            "\timport ContainerAPIClient",                         // 前置 tab
            "@preconcurrency import ContainerAPIClient",           // 前置属性
            "@_implementationOnly import ContainerAPIClient",      // 前置下划线属性
            "@_spi(Private) import ContainerAPIClient",            // ★ 带括号参数的属性
            "@_spi(X) @preconcurrency import ContainerAPIClient",  // ★ 多个属性叠加
            "import struct ContainerAPIClient.ContainerSnapshot",  // ★ import kind：只引入单个类型
            "import enum ContainerAPIClient.XPCRoute",
            "@_spi(P) import struct ContainerAPIClient.Snapshot",  // ★ 属性 + kind 组合
            "public import ContainerAPIClient",                    // ★ Swift 6 access-level import
            "package import ContainerAPIClient",
            "internal import struct ContainerAPIClient.Snapshot",  // ★ access-level + kind
            "/* 备注 */ import ContainerAPIClient",                 // ★ 块注释之后是活代码
            "import ContainerAPIClient  // 顺手加的",               // ★ 行尾注释不影响前面的活代码
            "import class Containerization.Foo",
        ]
    )
    func detectsUpstreamImport(source: String) {
        let violations = BoundaryScanner.upstreamImports(in: source, modules: Self.upstreamModules)
        #expect(violations.count == 1, "漏掉了越界 import：\(source)")
    }

    /// 反向：合法源码不能被误报，否则扫描器会因为太吵而被关掉——那等于没有扫描器。
    @Test(
        "不误报合法源码",
        arguments: [
            "import Foundation",
            "import Testing",
            "// import ContainerAPIClient —— 注释掉的不算",
            "import ContainerAPIClientHelper",                     // 前缀相同的另一个模块
        ]
    )
    func ignoresLegitimateSource(source: String) {
        let violations = BoundaryScanner.upstreamImports(in: source, modules: Self.upstreamModules)
        #expect(violations.isEmpty, "误报了合法源码：\(source)")
    }

    @Test("报出准确的行号")
    func reportsLineNumber() {
        let source = """
        import Foundation

        import struct ContainerAPIClient.ContainerSnapshot
        """

        let violations = BoundaryScanner.upstreamImports(in: source, modules: Self.upstreamModules)

        #expect(violations.count == 1)
        #expect(violations.first?.line == 3)
    }

    // MARK: - D-B'：裸 LogLine 的唯一消费者

    /// `LogLine` 可能以任意上下文出现——类型标注、泛型参数、构造调用……
    /// 规则不关心「怎么用的」，只要独立词命中就算。
    @Test(
        "抓得到各种形态的 LogLine 引用",
        arguments: [
            "let line: LogLine",
            "func f(_ x: LogLine) {}",
            "AsyncThrowingStream<LogLine, any Error>",
            "[LogLine]",
            "LogLine(text: \"x\")",
            "\tLogLine",  // 前置 tab
        ]
    )
    func detectsRawLogLineReference(source: String) {
        let violations = BoundaryScanner.identifierUsages(in: source, identifier: "LogLine")
        #expect(violations.count == 1, "漏掉了 LogLine 引用：\(source)")
    }

    /// **这条是这条规则存在的全部意义**：`RedactedLogLine` 里含 `LogLine` 子串，
    /// 若规则用子串匹配（而不是独立词），任何引用 `RedactedLogLine`（app 该看到的类型）
    /// 的合法代码都会被误报——误报多了规则会被关掉，那就等于没有规则。
    @Test("RedactedLogLine 不算越界引用（不是同一个词）")
    func ignoresRedactedLogLine() {
        let source = "let line: RedactedLogLine"
        #expect(BoundaryScanner.identifierUsages(in: source, identifier: "LogLine").isEmpty)
    }

    @Test("注释里的 LogLine 不算")
    func ignoresLogLineInComment() {
        let source = "// 这里以前用过 LogLine，后来改掉了"
        #expect(BoundaryScanner.identifierUsages(in: source, identifier: "LogLine").isEmpty)
    }

    @Test("一行里出现两次都各自命中")
    func countsEveryLogLineOccurrenceOnTheSameLine() {
        let source = "func map(_ line: LogLine) -> LogLine"
        #expect(BoundaryScanner.identifierUsages(in: source, identifier: "LogLine").count == 2)
    }

    // MARK: - D2：明文出口

    /// 上一版要求 `.reveal()` 与 sink 名（`logger` / `print(` …）**出现在同一行**才算违规。
    /// 下面第二、三条把它们拆到不同行，明文照样进日志，而上一版是绿的。
    ///
    /// 现在的规则不猜去向：任何 `.reveal()` 都必须登记。于是这些写法无一例外被抓住。
    @Test(
        "抓得到任意形态的明文出口",
        arguments: [
            #"logger.info("\(secret.reveal())")"#,   // 上一版唯一抓得到的形态
            "let plain = secret.reveal()",           // ★ 变量中转：下一行才 log
            #"    \(secret.reveal())"#,              // ★ 多行字符串里的插值，logger 在别的行
            "return env.value.reveal() + suffix",    // 拼进别的 String 再流走
        ]
    )
    func detectsRevealCallSite(source: String) {
        let violations = BoundaryScanner.revealCallSites(in: source)
        #expect(violations.count == 1, "漏掉了明文出口：\(source)")
    }

    /// 规则已经变成「数数」，那就必须数得准——这两条都是「该红时会绿」的漏算：
    /// 空参数列表里的空白是合法 Swift；一行里塞两个出口只被数成一个，
    /// 就能往已登记的那一行偷渡新的明文出口而预算不变。
    @Test("空参数列表里的空白不影响计数")
    func countsRevealWithWhitespaceInArgumentList() {
        #expect(BoundaryScanner.revealCallSites(in: "let p = secret.reveal( )").count == 1)
        #expect(BoundaryScanner.revealCallSites(in: "let p = secret . reveal ()").count == 1)
    }

    @Test("同一行的多个明文出口分别计数")
    func countsEveryRevealOnTheSameLine() {
        let source = "let pair = (a.reveal(), b.reveal())"
        #expect(BoundaryScanner.revealCallSites(in: source).count == 2)
    }

    @Test("没有 reveal 就没有违规")
    func ignoresSourceWithoutReveal() {
        let source = #"""
        logger.info("env \(variable.key) = \(variable.value)")
        let redacted = String(describing: secret)
        """#

        #expect(BoundaryScanner.revealCallSites(in: source).isEmpty)
    }

    // MARK: - D2：不可信文本以 .public 记入日志

    @Test("承载不可信文本的符号 + .public 同行 → 命中")
    func flagsPublicPrivacyOnMarkedText() {
        let source = #"log.error("detail=\(privateDetail(error), privacy: .public)")"#
        #expect(BoundaryScanner.publicPrivacyLeaks(in: source, markers: ["privateDetail"]).count == 1)
    }

    @Test("同一符号标 .private → 放行")
    func allowsPrivatePrivacyOnMarkedText() {
        let source = #"log.error("detail=\(privateDetail(error), privacy: .private)")"#
        #expect(BoundaryScanner.publicPrivacyLeaks(in: source, markers: ["privateDetail"]).isEmpty)
    }

    @Test(".public 但不含被标记的符号 → 放行（allowlist 的安全字段可以公开）")
    func ignoresPublicOnUnmarkedText() {
        let source = #"log.info("state=\(describe(state), privacy: .public)")"#
        #expect(BoundaryScanner.publicPrivacyLeaks(in: source, markers: ["privateDetail"]).isEmpty)
    }

    // MARK: - D2 函数级：明文出口的行区间定位

    @Test("定位到函数体的完整行区间")
    func locatesFunctionBodyRange() {
        let source = """
        enum M {
            static func serialize(_ env: [String]) -> [String] {
                env.map { "\\($0)" }
            }
        }
        """
        let range = BoundaryScanner.lineRangeOfFunction(named: "serialize", in: source)
        #expect(range == 2...4)
    }

    @Test("找不到该函数 → nil")
    func returnsNilForMissingFunction() {
        #expect(BoundaryScanner.lineRangeOfFunction(named: "missing", in: "let x = 1") == nil)
    }

    /// **这条是函数级锁存在的意义**：reveal 挪出被锁函数（进另一个 helper）时，
    /// 文件级预算（计数=1、仍在本文件）看不见——只有「reveal 行 ∈ 该函数区间」抓得到。
    @Test("reveal 挪出被锁函数 → 落在区间外（该红时会红）")
    func revealMovedOutOfLockedFunctionFallsOutsideRange() throws {
        let source = """
        enum M {
            static func serialize(_ env: [String]) -> [String] {
                env.map { "\\($0)" }
            }
            static func leak(_ s: Secret) -> String {
                s.reveal()
            }
        }
        """
        let range = try #require(BoundaryScanner.lineRangeOfFunction(named: "serialize", in: source))
        let revealLine = try #require(BoundaryScanner.revealCallSites(in: source).first?.line)
        #expect(range == 2...4)
        #expect(revealLine == 6)
        #expect(!range.contains(revealLine))   // 直陈不变式：reveal 落在被锁函数区间外。
    }

    // MARK: - R-SECRET2：configuration 进日志

    @Test(
        "抓得到 configuration 被送进各种 sink",
        arguments: [
            "logger.debug(\"cfg=\\(configuration)\")",
            "log.error(\"\\(config.initProcess.environment)\")",
            "print(configuration)",
            "dump(config)",
            "os_log(\"%@\", String(describing: ProcessConfiguration.self))",
            "logger.info(\"\\(config)\")",
            "log.debug(\"\\(sanitized)\")",   // clone 提交的真实明文 carrier（codex T7-review 抓的假阴）。
        ]
    )
    func detectsConfigurationLogSite(source: String) {
        #expect(BoundaryScanner.configurationLogSites(in: source).count == 1, "漏掉了 config 泄漏：\(source)")
    }

    @Test(
        "不误报合法源码",
        arguments: [
            "let config = try await Self.loadSystemConfig()",
            "return [config.build.image, config.vminit.image]",              // 有 config 无 sink
            "try await client.create(configuration: config, kernel: kernel)", // 有 configuration: 无 sink
            "logger.info(\"container started\")",                             // 有 sink 无 config
            "// dump(configuration) —— 注释掉的不算",
            "let systemConfig = try await Self.loadSystemConfig()",           // systemConfig 不是独立词 config
        ]
    )
    func ignoresLegitimateConfigLines(source: String) {
        #expect(BoundaryScanner.configurationLogSites(in: source).isEmpty, "误报了合法源码：\(source)")
    }

    // MARK: - R-HANG：上游调用未套超时

    @Test("wrapper 内的上游调用 → 放行")
    func allowsWrappedUpstreamCall() {
        let source = """
        func list() async throws {
            let x = try await XPCTimeout.race(after: t) {
                try await upstream.list()
            }
        }
        """
        let violations = BoundaryScanner.untimedUpstreamCalls(
            in: source, wrapper: "XPCTimeout.race", exemptMethods: []
        )
        #expect(violations.isEmpty)
    }

    /// **这条是超时扫描存在的意义**：漏套一个 XPCTimeout（本仓库栽过的回滚路径）时它必须红。
    @Test("裸上游调用（无 wrapper）→ 命中（该红时会红）")
    func flagsUntimedUpstreamCall() {
        let source = """
        func rollback() async {
            try? await upstream.stop(id: id)
        }
        """
        let violations = BoundaryScanner.untimedUpstreamCalls(
            in: source, wrapper: "XPCTimeout.race", exemptMethods: []
        )
        #expect(violations.count == 1)
        #expect(violations.first?.line == 2)
    }

    @Test("豁免方法（流式 pull）→ 放行")
    func exemptsStreamingMethod() {
        let source = """
        func pull() async {
            try await upstream.pullImage(reference: ref) { e in }
        }
        """
        let violations = BoundaryScanner.untimedUpstreamCalls(
            in: source, wrapper: "XPCTimeout.race", exemptMethods: ["pullImage"]
        )
        #expect(violations.isEmpty)
    }

    @Test("upstream 别名（usageUpstream）也被覆盖")
    func coversUpstreamAlias() {
        let source = """
        func collect() async {
            try await usageUpstream.volumeUsedBytes(name: n)
        }
        """
        let violations = BoundaryScanner.untimedUpstreamCalls(
            in: source, wrapper: "XPCTimeout.race", exemptMethods: []
        )
        #expect(violations.count == 1)
    }

    /// codex T7-review 补的洞：原正则只认紧跟 `await` 的标识符，`self.upstream` 会漏。
    @Test("self.upstream 限定写法也被抓（该红时会红）")
    func coversSelfQualifiedUpstream() {
        let source = """
        func rollback() async {
            try? await self.upstream.stop(id: id)
        }
        """
        let violations = BoundaryScanner.untimedUpstreamCalls(
            in: source, wrapper: "XPCTimeout.race", exemptMethods: []
        )
        #expect(violations.count == 1)
        #expect(violations.first?.line == 2)
    }

    @Test("非上游的 await 调用不被误报")
    func ignoresNonUpstreamAwaits() {
        let source = """
        func map() async {
            throw await errors.map(e)
            _ = await accumulator.fold(events)
            _ = await collector.collect(names: n)
        }
        """
        let violations = BoundaryScanner.untimedUpstreamCalls(
            in: source, wrapper: "XPCTimeout.race", exemptMethods: []
        )
        #expect(violations.isEmpty)
    }
}
