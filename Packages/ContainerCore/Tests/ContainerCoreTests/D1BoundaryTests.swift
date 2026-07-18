import BoundaryScanning
import Foundation
import Testing

/// D1 与 D2 的可执行证明。
///
/// PLAN 声称「上游类型只出现在 3 个 mapper + 1 个 live client，爆炸半径 = 4 个文件」。
/// 在这个测试存在之前，那句话没有任何东西保证——`ContainerCore` 不依赖上游，
/// 仅仅是因为「还没人往 Package.swift 里加依赖」。**因为没发生所以成立**，是最弱的成立方式。
///
/// 扫描规则本身在 `BoundaryScanner`，它自己被 `BoundaryScannerTests` 钉死（守卫的守卫）——
/// 否则一个漏扫的扫描器会恒绿，把「没人检查」伪装成「检查通过」。
@Suite("D1/D2 边界：上游类型不得渗透，明文出口必须登记")
struct D1BoundaryTests {

    /// 允许 `import ContainerAPIClient` 的文件（相对 `Sources/` 的路径）。
    ///
    /// M0：空集——本 target 零上游依赖。
    /// M1 起：只能是 SnapshotMapper / VolumeMapper / ImageMapper / StatsMapper + LiveContainerRuntimeClient，
    /// 且它们住在**另一个 target**。往这里加名字之前，先问一遍这是不是在扩大爆炸半径。
    static let filesAllowedToImportUpstream: Set<String> = []

    /// 明文出口**预算**：文件（相对 `Sources/` 的路径）→ 该文件允许有几个明文出口。
    ///
    /// 刻意不是 `Set<String>`（文件级白名单）：那样一旦某文件被登记，它内部**后续新增**的出口
    /// 就自动免检——审计记录当场断掉，而测试是绿的。粒度必须细到调用点。
    ///
    /// 实际数与预算**不等**（多了或少了）就红。多了 = 新增了未经 review 的明文出口；
    /// 少了 = 台账没跟上代码。两种都要求改这张表，而那一行 diff 就是这个出口的 review 记录。
    ///
    /// Day 9：`LogRedactor` 里那一次 `reveal()`——**为了匹配、不为了展示**。
    /// 取出该容器已知密钥的明文只是为了跟日志行做子串比较，明文永不落 ring buffer、
    /// 永不上屏、永不 log（Day 9 计划 D-B）。这是新增的唯一明文出口。
    static let plaintextExitBudget: [String: Int] = [
        "Streams/LogRedactor.swift": 1,
    ]

    /// ★ **app target 的明文出口预算**（P1-9，codex review 定案）。
    ///
    /// D2 原本只扫 `Sources/ContainerCore`——而生产代码里**第一次** `reveal()` 恰恰在 app 层的
    /// `SecretField`（用户点「显示」/「复制」）。那层不扫 = SecretField 之后任何人新加一个 reveal
    /// 都不会红，靠「只有这一个 view」的自觉守——正是这个仓库反复拒绝的「靠记得」。
    ///
    /// 于是把扫描伸进 `CradleOfFilth/`，给 app 单独一张预算表。粒度到调用点：
    /// SecretField 里两处（展开显示 + 复制），一处都不能多。
    static let appPlaintextExitBudget: [String: Int] = [
        "Components/SecretField.swift": 2,
    ]

    /// D-B'（Day 9 计划）：裸 `LogLine`（未脱敏）的唯一消费者是 `LogTailer`——
    /// app 只该看到 `RedactedLogLine`。任何越界引用都必须先在这里看见，才谈得上是不是蓄意。
    static let filesAllowedToReferenceRawLogLine: Set<String> = [
        "Domain/LogLine.swift",                      // 定义处
        "Runtime/ContainerRuntimeClient.swift",       // protocol 的 followLogs 返回它
        "Streams/LogTailer.swift",                    // 唯一消费者
        "Testing/FakeContainerRuntimeClient.swift",   // 测试替身要构造它来注入
    ]

    /// 上游模块名。碰到任何一个都算越界。
    static let upstreamModules = [
        "ContainerAPIClient",
        "ContainerizationOCI",
        "ContainerizationOS",
        "Containerization",
        "ContainerResource",
    ]

    @Test("ContainerCore 零上游 import")
    func noUpstreamImportsInCore() throws {
        let offenders = try Self.swiftSources()
            .filter { !Self.filesAllowedToImportUpstream.contains($0.relativePath) }
            .flatMap { file in
                BoundaryScanner
                    .upstreamImports(in: file.contents, modules: Self.upstreamModules)
                    .map { "\(file.relativePath):\($0.line) — \($0.text.trimmed)" }
            }

        #expect(
            offenders.isEmpty,
            """
            上游类型渗透进 ContainerCore（D1 被破坏）：
            \(offenders.joined(separator: "\n"))

            上游类型只准出现在 mapper 与 live client 里。若这是有意的，
            先确认它没把爆炸半径从 4 个文件扩大。
            """
        )
    }

    /// D2 的类型级防护只挡得住**被动**泄漏。主动泄漏——`reveal()` 拿到的是裸 `String`，
    /// 脱敏不再跟着它走——类型系统拦不住。那道口子只能靠这个测试守。
    ///
    /// **不去猜明文流向哪里**：猜 sink 名的写法已被证明能绕（变量中转、跨行 logger 调用都逃得掉，
    /// 且逃掉时测试是绿的）。规则改为：`Sources/` 下任何 `.reveal()` 都必须登记。
    /// 不猜去向，只锁数量。
    @Test("明文出口必须登记")
    func plaintextExitsAreAllRegistered() throws {
        let discrepancies = try Self.swiftSources().compactMap { file -> String? in
            let sites = BoundaryScanner.revealCallSites(in: file.contents)
            let budget = Self.plaintextExitBudget[file.relativePath] ?? 0
            guard sites.count != budget else { return nil }

            let listed = sites.map { "        \($0.line): \($0.text.trimmed)" }.joined(separator: "\n")
            return "\(file.relativePath)：预算 \(budget) 个，实际 \(sites.count) 个\n\(listed)"
        }

        #expect(
            discrepancies.isEmpty,
            """
            明文出口的账实不符（D2 被绕过）：
            \(discrepancies.joined(separator: "\n"))

            reveal() 的结果是裸 String，脱敏不再跟着它走：它可能被拼进日志、写进文件、进剪贴板。
            确实需要这个明文出口，就去改 plaintextExitBudget——那一行 diff 就是它的 review 记录。
            """
        )
    }

    /// ★ Day 8：`OSLogSupervisorLog` 里不可信的上游文本（`RuntimeError` 的 reason/path）
    /// 绝不许以 `.public` 记入日志。
    ///
    /// 它是覆盖率豁免的薄壳，spy 测试证明不了 `os.Logger` 插值的隐私标注——这条源码扫描补上。
    /// 承载不可信文本的符号是 `privateDetail`；它出现的那一行只准 `.private`。
    /// 突变验证过（`BoundaryScannerTests`）：把它改成 `.public` → 立刻红。
    @Test("os.Logger 不把上游文本记成 .public")
    func upstreamTextNeverLoggedPublic() throws {
        let target = "Support/OSLogSupervisorLog.swift"
        let file = try Self.swiftSources().first { $0.relativePath == target }

        let osLog = try #require(file, "找不到 \(target)——扫描靶子丢了（改名 / 移动？），这条守卫已失效")
        let leaks = BoundaryScanner.publicPrivacyLeaks(in: osLog.contents, markers: ["privateDetail"])

        #expect(
            leaks.isEmpty,
            """
            OSLogSupervisorLog 把不可信的上游文本记成了 .public（D2 被绕过）：
            \(leaks.map { "  \($0.line): \($0.text.trimmed)" }.joined(separator: "\n"))

            RuntimeError 的 reason/path 可能含用户名 / 项目名，将来还可能被上游塞进 env。
            它只准走 privateDetail(...) 且标 .private。
            """
        )
    }

    /// ★ P1-9：app target 的明文出口也必须登记。SecretField 是生产代码第一个 `reveal()`。
    @Test("app 层明文出口必须登记")
    func appPlaintextExitsAreAllRegistered() throws {
        let discrepancies = try Self.appSources().compactMap { file -> String? in
            let sites = BoundaryScanner.revealCallSites(in: file.contents)
            let budget = Self.appPlaintextExitBudget[file.relativePath] ?? 0
            guard sites.count != budget else { return nil }

            let listed = sites.map { "        \($0.line): \($0.text.trimmed)" }.joined(separator: "\n")
            return "\(file.relativePath)：预算 \(budget) 个，实际 \(sites.count) 个\n\(listed)"
        }

        #expect(
            discrepancies.isEmpty,
            """
            app 层明文出口的账实不符（D2 被绕过）：
            \(discrepancies.joined(separator: "\n"))

            新增了明文出口就去改 appPlaintextExitBudget——那一行 diff 就是它的 review 记录。
            reveal() 的结果是裸 String，脱敏不再跟着它走。
            """
        )
    }

    /// ★ D-B'：裸 `LogLine` 流只被 `LogTailer` 消费。
    @Test("裸 LogLine 只被 LogTailer 消费")
    func rawLogLineOnlyConsumedByLogTailer() throws {
        let offenders = try Self.swiftSources()
            .filter { !Self.filesAllowedToReferenceRawLogLine.contains($0.relativePath) }
            .flatMap { file in
                BoundaryScanner
                    .identifierUsages(in: file.contents, identifier: "LogLine")
                    .map { "\(file.relativePath):\($0.line) — \($0.text.trimmed)" }
            }

        #expect(
            offenders.isEmpty,
            """
            裸 LogLine（未脱敏）越出了它的白名单（D-B' 被破坏）：
            \(offenders.joined(separator: "\n"))

            app 只该看到 RedactedLogLine。确实需要新增消费者，先确认这不是绕开脱敏的捷径，
            再把文件加进 filesAllowedToReferenceRawLogLine——那一行 diff 就是它的 review 记录。
            """
        )
    }

    // MARK: - 源码收集

    /// 只扫**产品 target 的目录**，不扫整个 `Sources/`。
    ///
    /// 同一个 package 里还住着 `Sources/BoundaryScanning/`——扫描器自己。它的源码里必然含
    /// import 样例与 `.reveal()` 的正则字面量，扫到它就是**自指假阳性**（规则没错，靶子选错了）。
    ///
    /// 用 `#filePath` 定位 package root：测试的 CWD 不可靠（`swift test` 与 Xcode 各跑各的）。
    /// 目录扫空会 `throw`（不是返回空数组）——「没有违规」和「没有检查」必须长得不一样。
    static func swiftSources() throws -> [BoundaryScanner.SourceFile] {
        let packageRoot = URL(filePath: #filePath)      // Tests/ContainerCoreTests/D1BoundaryTests.swift
            .deletingLastPathComponent()                 // Tests/ContainerCoreTests
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // <package root>

        return try BoundaryScanner.swiftSources(
            under: packageRoot.appending(path: "Sources/ContainerCore")
        )
    }

    /// app target 的源码（`CradleOfFilth/`）。从本文件往上走到 repo 根再进 app 目录。
    ///
    /// 扫空会 `throw`（不是返回空）——app 目录挪了 / 改名了，「没有违规」和「没检查」必须长得不一样。
    static func appSources() throws -> [BoundaryScanner.SourceFile] {
        let repoRoot = URL(filePath: #filePath)          // .../ContainerCoreTests/D1BoundaryTests.swift
            .deletingLastPathComponent()                  // ContainerCoreTests
            .deletingLastPathComponent()                  // Tests
            .deletingLastPathComponent()                  // ContainerCore（package root）
            .deletingLastPathComponent()                  // Packages
            .deletingLastPathComponent()                  // repo root

        return try BoundaryScanner.swiftSources(
            under: repoRoot.appending(path: "CradleOfFilth")
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
