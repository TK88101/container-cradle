import BoundaryScanning
import Foundation
import Testing

/// **D1 在这一侧的证明：爆炸半径就是这几个文件，一个不多。**
///
/// `ContainerCore` 那边守的是「零上游依赖」，而且它现在由**编译器**强制
/// （那个 package 的 Package.swift 里根本没有上游依赖，想 import 也 import 不到）。
///
/// 这一侧守的是另一件事：上游依赖**允许**存在，但必须**被数着**。
/// PLAN 声称「上游类型只出现在 3 个 mapper + 1 个 live client，爆炸半径 = 4 个文件」——
/// 在这个测试存在之前，那句话没有任何东西保证。
///
/// 往白名单里加名字之前，先问一遍：这是不是在扩大爆炸半径。那一行 diff 就是它的 review 记录。
@Suite("D1：ContainerRuntime 的爆炸半径")
struct RuntimeBoundaryTests {

    /// 允许 `import` 上游的文件（相对 `Sources/ContainerRuntime/`）。
    static let filesAllowedToImportUpstream: Set<String> = [
        "UpstreamClient.swift",              // 唯一打 XPC 的 adapter
        "SnapshotMapper.swift",              // 上游改字段，只有它编译不过
        "RuntimeErrorMapper.swift",          // 上游错误 → domain 错误
        "LiveContainerRuntimeClient.swift",  // 那段 start 序列（要看 snapshot 的 status/mounts）
        "StatsMapper.swift",                 // 上游 ContainerStats → domain ContainerStatsSample（Day 9 M4）
        "VolumeMapper.swift",                // 上游 VolumeConfiguration → domain Volume（Day 10 M5）
        "ImageMapper.swift",                 // 上游 ImageDescription → domain ImageSummary（Day 10 M5）
        "CreationMapper.swift",              // domain ContainerCreationSpec → 上游 Flags.*（Day 16 T4）
        "PullMapper.swift",                  // 上游 ProgressUpdateEvent → domain PullProgress（Day 16 T5）
        // 注：`VolumeUsageCollector.swift` 刻意**不在**名单里——它只碰 String/UInt64，
        // 不 import 上游。哪天它想 import，这个测试就是拦它的闸。
    ]

    static let upstreamModules = [
        "ContainerAPIClient",
        "ContainerResource",
        "TerminalProgress",   // pull 进度事件 ProgressUpdateEvent（Day 16 T5：PullMapper 唯一 import 处）
        "ContainerizationOCI",
        "ContainerizationOS",
        // `ContainerizationError` 必须单列：扫描器认的是**独立词**，
        // `Containerization` 的模式匹配不到 `ContainerizationError`（后面还跟着字母）。
        "ContainerizationError",
        "Containerization",
    ]

    @Test("上游 import 只出现在白名单里的文件")
    func upstreamImportsStayInsideBlastRadius() throws {
        let offenders = try Self.swiftSources()
            .filter { !Self.filesAllowedToImportUpstream.contains($0.relativePath) }
            .flatMap { file in
                BoundaryScanner
                    .upstreamImports(in: file.contents, modules: Self.upstreamModules)
                    .map { "\(file.relativePath):\($0.line) — \($0.text.trimmingCharacters(in: .whitespaces))" }
            }

        #expect(
            offenders.isEmpty,
            """
            爆炸半径变大了（D1）：
            \(offenders.joined(separator: "\n"))

            上游改一个字段，要重写的文件就多一个。确实需要的话，去改
            filesAllowedToImportUpstream——那一行 diff 就是这个决定的 review 记录。
            """
        )
    }

    /// 白名单里的文件必须**真的存在**。
    ///
    /// 少了这一条，白名单会烂掉：文件改了名、删了，白名单里的旧名字还在——
    /// 而它现在什么都不豁免了，测试却照样绿。名单和现实脱钩的那一刻，它就不再是名单了。
    @Test("白名单里没有幽灵条目")
    func whitelistHasNoGhosts() throws {
        let actual = Set(try Self.swiftSources().map(\.relativePath))
        let ghosts = Self.filesAllowedToImportUpstream.subtracting(actual)

        #expect(ghosts.isEmpty, "白名单里的文件已经不存在了：\(ghosts.sorted())")
    }

    /// **Day 16 T4 起：明文出口预算 = 恰好 1，且只准在 `CreationMapper.swift`。**
    ///
    /// Day 15 前预算恒 0：mapper 只把明文**装进** `SecretString`，从不需要**取出来**。
    /// T4 开了唯一一个口子——create/clone 必须把 env 明文交给上游 `Flags.Process.env`，
    /// 那个 `.reveal()` 住在 `CreationMapper.serializeEnvironmentForCreate`（D2 唯一出口）。
    /// 别处任何 `.reveal()` 都是设计出了问题。
    ///
    /// 这是**保绿最小档**（T4）：锁「只在 CreationMapper.swift + 计数恰为 1」。
    /// T7 会把「恰在 `serializeEnvironmentForCreate` 函数体内」再锁死一层 + 跑突变验证
    /// （reveal 挪出助手 → 该红时会红）。
    static let fileAllowedToRevealPlaintext = "CreationMapper.swift"

    @Test("明文出口预算恰为 1，且只在 CreationMapper")
    func plaintextExitsStayInBudget() throws {
        let sources = try Self.swiftSources()

        let offenders = sources
            .filter { $0.relativePath != Self.fileAllowedToRevealPlaintext }
            .flatMap { file in
                BoundaryScanner.revealCallSites(in: file.contents)
                    .map { "\(file.relativePath):\($0.line)" }
            }

        #expect(
            offenders.isEmpty,
            """
            `CreationMapper.swift` 之外出现了明文出口：
            \(offenders.joined(separator: "\n"))

            mapper 的职责是把明文装进 SecretString。唯一合法的取出点是
            CreationMapper.serializeEnvironmentForCreate（create 必须把 env 明文交给上游）。
            """
        )

        let allowedCount = sources
            .first { $0.relativePath == Self.fileAllowedToRevealPlaintext }
            .map { BoundaryScanner.revealCallSites(in: $0.contents).count } ?? 0

        #expect(
            allowedCount == 1,
            """
            CreationMapper 的明文出口预算是 1，实际 \(allowedCount)。
            多一个 reveal 都要显式改这条预算——那一行 diff 就是这个决定的 review 记录。
            """
        )
    }

    /// **Day 16 T7：把明文出口从「文件级」收窄到「函数级」。**
    ///
    /// `plaintextExitsStayInBudget` 只锁「在 `CreationMapper.swift` + 计数=1」——文件级。
    /// 有人把那唯一的 reveal **挪出** `serializeEnvironmentForCreate`（进同文件另一个 helper）时，
    /// 计数仍是 1、文件仍是它——文件级锁看不见。这条把它钉到函数体内：那个 reveal 必须恰好
    /// 落在 `serializeEnvironmentForCreate` 的行区间里。
    ///
    /// 突变验证（T7，已跑并记于 plan 附录 B）：把 line 128 的 `.reveal()` 挪进 `volumeArgument`
    /// → 本测试红（reveal 行落在函数区间外），`plaintextExitsStayInBudget` 仍绿（计数没变）——
    /// 正是函数级锁存在的意义。
    static let functionAllowedToRevealPlaintext = "serializeEnvironmentForCreate"

    @Test("唯一的明文出口恰在 serializeEnvironmentForCreate 函数体内")
    func plaintextExitLivesInSerializeHelper() throws {
        let mapper = try #require(
            try Self.swiftSources().first { $0.relativePath == Self.fileAllowedToRevealPlaintext },
            "找不到 \(Self.fileAllowedToRevealPlaintext)"
        )

        let reveals = BoundaryScanner.revealCallSites(in: mapper.contents)
        #expect(reveals.count == 1, "明文出口不止一个：\(reveals.map(\.line))")

        let range = try #require(
            BoundaryScanner.lineRangeOfFunction(
                named: Self.functionAllowedToRevealPlaintext, in: mapper.contents
            ),
            "定位不到 \(Self.functionAllowedToRevealPlaintext) 的行区间"
        )

        for reveal in reveals {
            #expect(
                range.contains(reveal.line),
                """
                明文出口在 \(Self.fileAllowedToRevealPlaintext):\(reveal.line)，
                不在 \(Self.functionAllowedToRevealPlaintext)（\(range.lowerBound)…\(range.upperBound)）内。
                create/clone 之外的明文取出都是设计出了问题——要么改回助手里，要么显式改这条锁。
                """
            )
        }
    }

    /// ★ **R-HANG：每个上游调用都套 `XPCTimeout`，靠形状不靠记得（§3.7 / codex #15）。**
    ///
    /// 「每个上游调用都套 XPCTimeout」这句话写在 `LiveContainerRuntimeClient` 开头，
    /// 而本仓库**因漏写一个**栽过（回滚路径那句 `try? await stop` 当初没套 → XPC 在回滚上不回话
    /// 就冻住 supervisor，坑清单）。注释拦不住漏写，扫源码才行：`LiveContainerRuntimeClient.swift`
    /// 里任何 `await upstream.<method>(` 都必须词法嵌在 `XPCTimeout.race { }` 内。
    ///
    /// **唯一豁免 = 流式 `pullImage`**（无界下载、以进度作 liveness、不在 reconcile 路径、控制走流取消
    /// 而非计时）。豁免名单写死在这里 = 每加一个豁免都是一行留痕的 diff。
    ///
    /// 突变验证（T7，已跑并记于 plan 附录 B）：拆掉 `stop()` 回滚那句的 `XPCTimeout.race` 包裹
    /// → 本测试立刻报出那一行。
    static let upstreamMethodsExemptFromTimeout: Set<String> = [
        "pullImage",   // 流式，控制走流取消（见 LiveContainerRuntimeClient.pullImage 注释）
    ]

    @Test("每个上游调用都套 XPCTimeout（唯一豁免：流式 pull）")
    func upstreamCallsAreTimeoutBounded() throws {
        let liveClient = try #require(
            try Self.swiftSources().first { $0.relativePath == "LiveContainerRuntimeClient.swift" },
            "找不到 LiveContainerRuntimeClient.swift"
        )

        let offenders = BoundaryScanner.untimedUpstreamCalls(
            in: liveClient.contents,
            wrapper: "XPCTimeout.race",
            exemptMethods: Self.upstreamMethodsExemptFromTimeout
        )

        #expect(
            offenders.isEmpty,
            """
            有上游调用没套 XPCTimeout（会冻住 supervisor，R-HANG）：
            \(offenders.map { "  LiveContainerRuntimeClient.swift:\($0.line)  \($0.detail)" }.joined(separator: "\n"))

            每个 `await upstream.X` 都要包在 `XPCTimeout.race { }` 里。确实要豁免（如新的流式接口），
            去改 upstreamMethodsExemptFromTimeout——那一行 diff 就是这个决定的 review 记录。
            """
        )
    }

    /// ★ **R-SECRET2：clone 复用的明文 configuration 绝不进日志（第二密钥路径，codex #6）。**
    ///
    /// clone 复用源 `ContainerConfiguration`，其 `initProcess.environment` 是明文 `[String]`、
    /// **不经 `SecretString`**——`plaintextExitsStayInBudget` 的 reveal 扫描**抓不到它**。
    /// 唯一的堵法是禁止把 configuration 送进任何 log / print / dump sink。
    ///
    /// 突变验证（T7，已跑并记于 plan 附录 B）：在 `sanitizeForClone` 里加一句
    /// `Self.log.debug("\(config)")` → 本测试立刻报出那一行。
    @Test("clone 复用的 configuration 从不进日志")
    func cloneConfigurationIsNeverLogged() throws {
        let offenders = try Self.swiftSources().flatMap { file in
            BoundaryScanner.configurationLogSites(in: file.contents)
                .map { "\(file.relativePath):\($0.line)  \($0.text.trimmingCharacters(in: .whitespaces))" }
        }

        #expect(
            offenders.isEmpty,
            """
            configuration 被送进了日志 / print / dump（第二密钥路径泄漏，R-SECRET2）：
            \(offenders.joined(separator: "\n"))

            clone 复用的 configuration 里 env 是明文、不经 SecretString——reveal 扫描抓不到它，
            所以它绝不能进任何 sink。要诊断就 log 具体的安全字段（id / image），别 log 整个 config。
            """
        )
    }

    /// ★★★ **XPC 客户端不许被存起来跨代复用**（Day 7 的 M3 验收红了才挖出来的 P0）。
    ///
    /// 上游 `ContainerClient` 在 init 时建一条 mach service 连接就 activate，
    /// 而 `container system stop` 会把那个 service 卸掉——连接进入 **INVALID**，
    /// 那是**终态**：不自愈、不重连。存起来复用的话，运行时一换代，
    /// App 手里就是一条死连接：`list()` 全失败、reconcile 连败 5 次 → 熔断。
    ///
    /// **这个 App 存在的唯一理由就是熬过 apiserver 重启，而它的客户端曾经熬不过。**
    ///
    /// 这条不变式**单元测试守不住**（要复现得真把 apiserver 停掉再起），
    /// 真正的守卫是 M3 那趟真机验收。这里是第二道：**扫源码**。
    /// 文本启发式拦得住不小心（某天有人觉得「每次新建太浪费，缓存一下吧」），
    /// 拦不住蓄意——而不小心恰恰是这个 bug 第一次进来的方式。
    @Test("XPC 客户端每次现建，不得存成属性")
    func upstreamClientIsNeverCached() throws {
        let offenders = try Self.swiftSources().flatMap { file in
            file.contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, line in
                    // 存储属性形态：`let x = ContainerClient()`。
                    // 计算属性（`var client: ContainerClient { ContainerClient() }`）不在此列；
                    // 函数体里的 `let client = self.client` 也不是（它没有 `ContainerClient(`）。
                    let text = line.trimmingCharacters(in: .whitespaces)

                    guard text.hasPrefix("let ") || text.hasPrefix("private let ") else {
                        return false
                    }

                    return text.contains("ContainerClient(")
                }
                .map { index, line in
                    "\(file.relativePath):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))"
                }
        }

        #expect(
            offenders.isEmpty,
            """
            XPC 客户端被存成了属性：
            \(offenders.joined(separator: "\n"))

            连接不许跨越运行时的代——`container system stop` 之后它是终态失效的死连接，
            而运行时换代正是这个 App 唯一该发挥作用的时刻。每次调用现建现用。
            """
        )
    }

    /// ★ **Day 16 T6.6：五能力落地后，桩标记必须归零。**
    ///
    /// T3 先把协议 +5 桩成 typed-throws（保绿），T4-T6 逐个接线。全部接线后，桩标记
    /// 不该再出现在 `Sources` 里。**留一个没接线的桩会编译过、仓库绿**，却在运行时对每个调用
    /// 抛 `operationFailed`——「桩当成完成」正是长任务最容易漏的一环。扫源码钉死它。
    @Test("Day 16 桩标记已全部拆除")
    func noDay16StubsRemain() throws {
        // 拆写字面量：`swiftSources()` 只扫 Sources/，本测试文件本就不在扫描范围内，
        // 但拆开也免得全仓 grep 把这一行算进「未拆的桩」。
        let marker = "DAY16" + "-STUB"

        let offenders = try Self.swiftSources().flatMap { file in
            file.contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { $0.element.contains(marker) }
                .map { "\(file.relativePath):\($0.offset + 1)" }
        }

        #expect(
            offenders.isEmpty,
            """
            还有 Day 16 的桩没拆（编译绿但运行时抛 operationFailed）：
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    static func swiftSources() throws -> [BoundaryScanner.SourceFile] {
        let packageRoot = URL(filePath: #filePath)   // Tests/ContainerRuntimeTests/RuntimeBoundaryTests.swift
            .deletingLastPathComponent()             // Tests/ContainerRuntimeTests
            .deletingLastPathComponent()             // Tests
            .deletingLastPathComponent()             // <package root>

        return try BoundaryScanner.swiftSources(
            under: packageRoot.appending(path: "Sources/ContainerRuntime")
        )
    }
}
