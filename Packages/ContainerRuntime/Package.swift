// swift-tools-version: 6.0
import PackageDescription

// **上游依赖的隔离区。** 整个仓库里唯一 import `ContainerAPIClient` 的地方。
//
// ## 为什么是独立 package，不是 ContainerCore 里的一个 target
//
// 两个理由，都是实测出来的：
//
// 1. **D1 从「源码扫描保证」升级成「编译期物理不可能」。** 同 package 加 target 的话，
//    `ContainerCore` 的 Package.swift 里就有了上游依赖——它「零上游」只剩下 `D1BoundaryTests`
//    的正则在守（文本启发式，拦得住不小心，拦不住蓄意）。分成两个 package，
//    `ContainerCore/Package.swift` 里根本没有这条依赖：想 import 上游，**编译器直接拒绝**。
//
// 2. **保住 6.3 秒的测试循环。** `swift test` 会构建 package 内的全部 target。
//    上游一旦进了 ContainerCore 的 package，reducer 改一行就要付 15.7 秒的增量构建税
//    （`Spikes/SPIKE-RESULT.md` 实测）——而 reducer 正是改得最频繁的地方。
//    分开之后，那 15.7 秒只在真的改 mapper 时才付。
//
// 代价（已认）：两个 package、CI 跑两条 `swift test`、Xcode 工程要引两个。
//
// ## 三个 product，不是一个
//
// 直觉是「加 `ContainerAPIClient` 就够了」。**不够**，已核实源码：
// - `ContainerClient` / `ProcessIO` / `ClientProcess` → `ContainerAPIClient`
// - `ContainerSnapshot` / `RuntimeStatus` / `Filesystem` / `ContainerStopOptions` → **`ContainerResource`**（另一个 product）
// - `ContainerizationError` → 由 **`Containerization`** product 导出（library "Containerization"
//   的 targets 里含 "ContainerizationError"；没有叫 `ContainerizationError` 的 product）
//
// 上游没有任何 `@_exported import`，什么都不白送。
let package = Package(
    name: "ContainerRuntime",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContainerRuntime", targets: ["ContainerRuntime"]),
    ],
    dependencies: [
        .package(path: "../ContainerCore"),

        // `exact:` 不是 `from:`——上游明确没有 API 稳定性承诺（那些 public 是跨 module 的
        // 技术需要，不是契约）。`from:` 会让 1.2.0 悄悄进来改字段，而我们的 mapper
        // 会在运行时静默地映射出错误的东西。R1。
        .package(url: "https://github.com/apple/container.git", exact: "1.1.0"),

        // **不是新增依赖**——`containerization` 本来就在依赖图里（container 1.1.0 自己 pin 的
        // 就是 0.35.0，见 Package.resolved）。这里只是把它**显式化**，因为 SPM 不允许
        // 借用传递依赖的 product，而 `ContainerizationError`（错误分类要用）由它导出：
        // 上游的 library "Containerization" 的 targets 里含 "ContainerizationError"，
        // **没有**叫 `ContainerizationError` 的 product。
        //
        // 两个 `exact:` 必须对得上。将来 container 升级换了 containerization 版本，
        // 这里会**解析失败**——响亮地失败，而不是悄悄拉进两份不兼容的类型。
        .package(url: "https://github.com/apple/containerization.git", exact: "0.35.0"),

        // 同上——swift-system 也是传递依赖的显式化（Package.resolved 已 pin 1.7.4）：
        // M5 的 infra 镜像过滤要走 CLI 同源的 config 加载路径（`ClientHealthCheck.ping`
        // → `ConfigurationLoader.configurationFile(in:of:)`），后者的入参类型 `FilePath`
        // 由 `SystemPackage` 导出。exact 对不上会解析失败——响亮地失败。
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.7.4"),
    ],
    targets: [
        .target(
            name: "ContainerRuntime",
            dependencies: [
                .product(name: "ContainerCore", package: "ContainerCore"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                // M5（Day 10）：infra 镜像过滤的 config 加载（`ContainerSystemConfig` /
                // `ConfigurationLoader`）。container 包自己的 product，同一个 exact pin。
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .testTarget(
            name: "ContainerRuntimeTests",
            dependencies: [
                "ContainerRuntime",
                .product(name: "ContainerCore", package: "ContainerCore"),
                // 自己的边界也要有人守：本 package 的爆炸半径若无人钉，
                // 「上游类型只出现在 4 个文件」就又变回一句口号。
                .product(name: "BoundaryScanning", package: "ContainerCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
