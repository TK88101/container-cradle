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
        // 注：`VolumeUsageCollector.swift` 刻意**不在**名单里——它只碰 String/UInt64，
        // 不 import 上游。哪天它想 import，这个测试就是拦它的闸。
    ]

    static let upstreamModules = [
        "ContainerAPIClient",
        "ContainerResource",
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

    /// D2：本 package 的 `Sources/` 下**不许有明文出口**。
    ///
    /// mapper 只负责把明文**装进** `SecretString`，从不需要把它**取出来**。
    /// 这里出现任何 `.reveal()` 都是设计出了问题。预算恒为 0。
    @Test("没有明文出口")
    func noPlaintextExits() throws {
        let exits = try Self.swiftSources().flatMap { file in
            BoundaryScanner.revealCallSites(in: file.contents)
                .map { "\(file.relativePath):\($0.line)" }
        }

        #expect(
            exits.isEmpty,
            """
            ContainerRuntime 里出现了明文出口：
            \(exits.joined(separator: "\n"))

            mapper 的职责是把明文装进 SecretString，不是把它取出来。
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
