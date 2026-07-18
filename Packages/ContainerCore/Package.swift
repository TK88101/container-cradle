// swift-tools-version: 6.0
import PackageDescription

// 唯一被强制的模块边界：**有没有上游依赖**。
//
// ContainerCore 是零上游依赖层——Domain / Supervisor / Polling / Persistence 全在这里。
// 它们互相之间用目录分，不用 target 分：再切 target 只会逼着一堆 internal 变 public，
// 换不来任何 D1 保障（D1 要的边界就是「碰不碰 ContainerAPIClient」这一条）。
//
// M1 才会新增依赖 ContainerAPIClient 的 ContainerRuntime target；
// ContainerRuntimeClient protocol 必须留在**本 target**（D1：签名里只有 domain 类型），
// 否则 Fake、Supervisor、reducer 测试全都要链上游，D1 当场崩掉，
// 且高频改动的 reducer 要付 15.7 秒增量构建税（Spikes/SPIKE-RESULT.md）。
//
// 「零上游依赖」不靠自觉：D1BoundaryTests 会扫源码，import 越界就红灯。
let package = Package(
    name: "ContainerCore",
    // Day 14 本地化：en = development language；core 展示串走
    // `String(localized:bundle:.module)`（DAY13 裁决 A 案）。
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContainerCore", targets: ["ContainerCore"]),

        // 只给**测试**用的工具库。产品 target 不依赖它 → 不进 app 二进制。
        //
        // 为什么要导出成 product：D1 的边界扫描规则现在有两个消费者——
        // ContainerCore 自己（守「零上游」）和 ContainerRuntime（守「爆炸半径 4 个文件」）。
        // 复制一份到另一个 package，两份规则必然漂；而扫描器一旦漂了，
        // 它守的那条不变式就会**恒绿**——看起来在守，其实什么都没守。
        // 规则只有一份，「守卫的守卫」测试（BoundaryScannerTests）也就只用写一份。
        .library(name: "BoundaryScanning", targets: ["BoundaryScanning"]),
    ],
    targets: [
        // 本地化接线的承重墙是 defaultLocalization，不是这条 resources 声明——
        // 突变实测（2026-07-18）：删 resources 声明，.lproj 仍被 SwiftPM 自动
        // 当本地化资源处理，测试照绿；删 defaultLocalization 才是 manifest 硬错。
        // 显式声明保留是为了走文档化行为，不押注自动侦测在未来工具链里不变。
        // key 回显类静默失败由 LocalizationResourceTests 守（zh-Hans exact 断言）。
        .target(
            name: "ContainerCore",
            resources: [.process("Resources")]
        ),

        // 零依赖、纯函数（源码字符串 → 违规行）。故它自己可以被测（该红时会红）。
        .target(name: "BoundaryScanning"),

        .testTarget(
            name: "ContainerCoreTests",
            dependencies: ["ContainerCore", "BoundaryScanning"]
        ),
    ]
)
