import Foundation

/// 本地化资源命中探针（Day 14，codex #1 #2 采纳；Rev 1 改 lproj 机制）。
///
/// **为什么存在**：SPM 生成的 `Bundle.module` accessor 是包内部的 extension，
/// app target 跨 module 拿不到它——AppModel 的 DEBUG 启动断言只能经这个 public API
/// 探测 core 目录是否真的接上了。「key 回显」（资源没接上时 `String(localized:)`
/// 原样返回 key）是静默失败：编译绿、大部分测试也绿，只有真的去查一次才知道。
///
/// **为什么要显式解析语言子 bundle**（Rev 1 实测）：
/// `String(localized:bundle:locale:)` 的 `locale:` 只管插值格式化/复数规则，
/// **不驱动语言表选择**——强制语言查表必须自己找到 `<lang>.lproj` 子 bundle。
/// 产品 UI 路径不用这个：`.module` + 系统 per-app 语言走 `preferredLocalizations`。
public enum LocalizationProbe {

    /// 哨兵 key：复用 `VolumePresentation` 的真实条目，不发明一次性 key——
    /// 哨兵和产品串同生共死，目录里删掉这条真实文案时哨兵会跟着叫。
    public static let sentinelKey = "size unknown"

    /// 按 locale 解析哨兵串。资源没接上（或该语言缺 lproj）时返回值 ==
    /// `sentinelKey`（key 回显），调用方以此判定；接上时返回对应语言的翻译
    /// （zh-Hans:「大小未知」）。
    public static func sentinel(locale: Locale = .current) -> String {
        String(
            localized: String.LocalizationValue(sentinelKey),
            bundle: languageBundle(for: locale),
            locale: locale
        )
    }

    /// 把 module bundle 解析到指定语言的 lproj 子 bundle。
    ///
    /// ## ★ 产品路径（`.current`）必须交给 `.module`，不能按 `.current` 的语言码选 lproj
    ///
    /// **UI 语言 ≠ 格式化 locale**（codex Round 2 抓到）。`Bundle.module` 选哪个语言表，
    /// 靠的是 `preferredLocalizations`（= app 的 UI 语言，`AppleLanguages` / macOS per-app
    /// 语言），而 `Locale.current` 是**格式化 / 区域** locale——两者可以不同（UI=日语、
    /// 区域=美国）。若按 `.current` 的语言码去挑 lproj，core 串会显示成区域语言，
    /// 与 app 目录（走 preferredLocalizations）当场打架。`preferredLocalizations` 是
    /// UI 语言的**权威来源**，所以产品路径直接返回 `.module`，correct-by-construction。
    ///
    /// ## 强制子 bundle 只为测试确定性
    ///
    /// `String(localized:bundle:locale:)` 的 `locale:` **不驱动语言表选择**（实测）——
    /// 要在 en 机器上测 zh-Hans，只能显式解析语言子 bundle。判据：调用方传了一个
    /// **不等于 `Locale.current`** 的显式 locale（`zh-Hans` / `en_US_POSIX`），才强制；
    /// 默认 `.current` 走上面的产品路径。（`Locale.current == Locale.current` 实测恒真。）
    ///
    /// **大小写不敏感匹配是必须的**：SwiftPM 会把 lproj 目录名小写化
    /// （`zh-Hans.lproj` → `zh-hans.lproj`，实测），`url(forResource:)` 却区分大小写。
    static func languageBundle(for locale: Locale) -> Bundle {
        // 产品路径：preferredLocalizations 说了算（UI 语言权威），不按格式化 locale 挑语言。
        guard locale != Locale.current else { return .module }

        // 测试强制路径：完整 identifier → 语言+script → 裸语言码，依次降级匹配子 bundle。
        var candidates = [locale.identifier.replacingOccurrences(of: "_", with: "-")]
        if let code = locale.language.languageCode?.identifier {
            if let script = locale.language.script?.identifier {
                candidates.append("\(code)-\(script)")
            }
            candidates.append(code)
        }

        let available = Bundle.module.localizations
        for candidate in candidates.map({ $0.lowercased() }) {
            guard let name = available.first(where: { $0.lowercased() == candidate }),
                let url = Bundle.module.url(forResource: name, withExtension: "lproj"),
                let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }
        return .module
    }
}

extension String {
    /// core 上屏串的统一入口：key = 英文源串，经语言子 bundle 解析（测试可强制语言），
    /// `locale` 同时驱动插值格式化与复数规则。UI 调用方默认 `.current`。
    init(coreLocalized value: String.LocalizationValue, locale: Locale) {
        self.init(
            localized: value,
            bundle: LocalizationProbe.languageBundle(for: locale),
            locale: locale
        )
    }
}
