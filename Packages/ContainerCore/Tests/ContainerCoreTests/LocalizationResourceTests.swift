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

    // MARK: - region-only zh → script 推断（P2-1，Day 15）

    /// `inferredScript` 是 zh 简繁归属由 region 决定这条领域规则的显式载体——
    /// 不依赖 Foundation `.language.script` 的 likely-subtags 自动补全（隐式契约，
    /// 环境/SDK 的 ICU 数据可能不补）。纯函数直接喂 region 断言，不必构造
    /// `.script == nil` 的 Locale（当前 SDK 构造不出）。
    @Test(
        "inferredScript：zh region 显式映射简繁；非 zh 返回 nil",
        arguments: [
            ("zh", "CN", "Hans"), ("zh", "SG", "Hans"),        // 简体区
            ("zh", "TW", "Hant"), ("zh", "HK", "Hant"), ("zh", "MO", "Hant"),  // 繁体区
            ("zh", nil, "Hans"),                                // 裸 zh → 简体默认
            ("en", "US", nil), ("ja", nil, nil),                // 非 zh → 不推断
        ] as [(languageCode: String, region: String?, expected: String?)]
    )
    func inferredScriptMapping(languageCode: String, region: String?, expected: String?) {
        #expect(LocalizationProbe.inferredScript(languageCode: languageCode, region: region) == expected)
    }

    /// region-only zh locale 端到端解析到正确 script 的 lproj。
    /// **断言 `bundlePath` 而非译文字形**——避简繁同形字肉眼不可分的假绿陷阱。
    ///
    /// **`.enabled(if:)` 防 flaky（codex Round 1 P2）**：`languageBundle` 对 `== Locale.current`
    /// 的 locale 会走产品路径 gate 短路成 `.module`。若开发机/CI 的 `Locale.current` 恰是某 zh
    /// locale，本组断言会因环境（而非本地化回归）假红。故 current 为 zh 时跳过——那台机器上
    /// 产品路径本就走 `.module` + `preferredLocalizations`，本测试要守的是**非-current 强制路径**。
    ///
    /// **突变验证（2026-07-19，跑过）**：临时删 `languageBundle` candidates 里
    /// `candidates.append("\(code)-\(script)")` 那行 → 本组三断言全红（退化回 `.module`，
    /// path 不含 zh-hans/zh-hant）→ 恢复回绿。证明 `.script ?? inferredScript` 接线在守。
    @Test(
        "region-only zh locale 端到端解析到正确 script 的 lproj（断言 bundlePath）",
        .enabled(
            if: Locale.current.language.languageCode?.identifier != "zh",
            "Locale.current 为 zh 时 languageBundle 走 .current gate 短路，端到端强制路径不可测"
        )
    )
    func regionOnlyZhResolvesToScriptLproj() {
        let cn = LocalizationProbe.languageBundle(for: Locale(identifier: "zh_CN"))
        #expect(cn.bundlePath.lowercased().contains("zh-hans"))

        let tw = LocalizationProbe.languageBundle(for: Locale(identifier: "zh_TW"))
        #expect(tw.bundlePath.lowercased().contains("zh-hant"))

        let bare = LocalizationProbe.languageBundle(for: Locale(identifier: "zh"))  // 裸 zh → 简体默认
        #expect(bare.bundlePath.lowercased().contains("zh-hans"))
    }
}
