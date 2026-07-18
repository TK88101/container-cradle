import Foundation
import Testing

// @testable：要直接打 `LocalizationProbe.languageBundle(for:)`（internal）与
// `Bundle.module`（SPM 生成的 internal accessor）——这不是要碰内部实现，
// 是资源 bundle 的可达性问题（app target 同理，所以有 public 的 Probe）。
@testable import ContainerCore

/// 资源双上下文命中专测——`swift test` 侧（DAY13 裁决 #7；app 运行态侧是
/// AppModel 的 DEBUG 双哨兵 + 真机四语清单）。
///
/// **守什么**：SPM 资源接线的静默失败形态是「key 回显」——`Package.swift` 的
/// `resources: [.process("Resources")]` 或 `defaultLocalization` 掉了、或 lproj
/// 没进 bundle，编译照绿，`String(localized:)` 原样返回 key。只有真的按
/// 非源语言查一次才暴露。
///
/// **Rev 1 实测教训（2026-07-18，本文件第一次上岗就抓到的）**：
/// core 目录不能用 xcstrings——`swift build` 只原样拷贝不编译，双上下文测试
/// 全红。改 `<lang>.lproj/Localizable.strings`（复数 `.stringsdict`）后转绿。
///
/// **突变验证（2026-07-18，两个突变点都跑过）**：
/// - 删 `defaultLocalization` → SwiftPM manifest 硬错（真正的承重墙）。
/// - 删 `resources:` 声明 → **照绿**（lproj 被自动侦测）——所以那条声明不是防线，
///   别指望它；防线是本文件的 zh-Hans exact 断言 + manifest 检查。
///
/// **三类 golden pattern（codex #3）**：普通串 / `%@` 插值 / `%lld` 复数
/// 三类各钉 zh-Hans（或 en 复数）exact 断言，后续所有条目照此结构写。
@Suite("本地化资源命中（swift test 上下文）")
struct LocalizationResourceTests {

    private let zhHans = Locale(identifier: "zh-Hans")
    private let en = Locale(identifier: "en")

    // MARK: - 普通串

    @Test("哨兵 key 经 zh-Hans 解析出翻译，不是 key 回显")
    func sentinelResolvesNonEcho() {
        let resolved = LocalizationProbe.sentinel(locale: zhHans)
        #expect(resolved != LocalizationProbe.sentinelKey)
        #expect(resolved == "大小未知")
    }

    @Test("哨兵 key 经 en（源语言）解析：等于 key 本身是正确行为——源语言无独立条目")
    func sentinelEnFallsBackToSource() {
        #expect(LocalizationProbe.sentinel(locale: en) == "size unknown")
    }

    @Test("languageBundle：大小写不敏感命中 SwiftPM 小写化的 lproj；未知语言回落 .module")
    func languageBundleResolution() {
        #expect(LocalizationProbe.languageBundle(for: zhHans) != Bundle.module)
        #expect(LocalizationProbe.languageBundle(for: Locale(identifier: "ko")) == Bundle.module)
    }

    // MARK: - %@ 插值

    @Test("插值 golden pattern：\\(String) 插值 → key 为 %@ 格式模式，zh-Hans 位置化重排生效")
    func interpolationGoldenPattern() {
        let text = String(
            localized: "\("70.1 MB") used / \("512 GB") max",
            bundle: LocalizationProbe.languageBundle(for: zhHans),
            locale: zhHans
        )
        #expect(text == "已用 70.1 MB / 上限 512 GB")
    }

    // MARK: - %lld 复数（en 走 en.lproj/Localizable.stringsdict）

    @Test("复数 golden pattern：en one/other variation 生效——1 不带 s")
    func pluralGoldenPatternEnglishOne() {
        let text = String(
            localized: "\(1) volumes",
            bundle: LocalizationProbe.languageBundle(for: en),
            locale: en
        )
        #expect(text == "1 volume")
    }

    @Test("复数 golden pattern：en other——2 带 s")
    func pluralGoldenPatternEnglishOther() {
        let text = String(
            localized: "\(2) volumes",
            bundle: LocalizationProbe.languageBundle(for: en),
            locale: en
        )
        #expect(text == "2 volumes")
    }

    @Test("复数 golden pattern：zh-Hans 无复数变形，单一 .strings 条目")
    func pluralGoldenPatternChinese() {
        let text = String(
            localized: "\(2) volumes",
            bundle: LocalizationProbe.languageBundle(for: zhHans),
            locale: zhHans
        )
        #expect(text == "2 个 volume")
    }
}
