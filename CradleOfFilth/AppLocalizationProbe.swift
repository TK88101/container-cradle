import ContainerCore
import Foundation

/// DEBUG 启动自检：**两本目录都必须真的接上了**（codex #1 #2）。
///
/// 「key 回显」是资源没接上时最常见的静默失败——编译绿、大部分测试也绿，
/// 只有真的按非源语言查一次才暴露。app target 没有测试 target，所以这道断言
/// 就是它在运行态的唯一自动守卫（另一半是真机四语清单）。
///
/// - **core 目录**（SPM lproj）：经 `LocalizationProbe`（public API，内部握 `.module`）探。
/// - **app 目录**（Xcode 编译的 xcstrings → main bundle）：这里自己按语言子 bundle 探。
///   `String(localized:locale:)` 的 `locale:` 不驱动语言表选择（core 侧实测同款），
///   所以强制语言查表必须显式解析 `Bundle.main` 的 `<lang>.lproj` 子 bundle。
enum AppLocalizationProbe {

    /// 两本目录都命中非回显翻译才返回 true。DEBUG 断言用。
    static func bothCatalogsWired() -> Bool {
        coreCatalogWired() && appCatalogWired()
    }

    private static func coreCatalogWired() -> Bool {
        let zhHans = Locale(identifier: "zh-Hans")
        return LocalizationProbe.sentinel(locale: zhHans) != LocalizationProbe.sentinelKey
    }

    /// app 目录哨兵 = "Containers"（zh-Hans → "容器"）。查不到子 bundle 或回显即判失败。
    private static func appCatalogWired() -> Bool {
        let key = "Containers"
        guard let bundle = mainLanguageBundle(for: "zh-Hans") else { return false }
        let resolved = bundle.localizedString(forKey: key, value: key, table: nil)
        return resolved != key
    }

    /// `Bundle.main` 里对应语言的 lproj 子 bundle。Xcode 编 xcstrings 时保留大小写
    /// （`zh-Hans.lproj`，与 SPM 的小写化不同），仍做大小写不敏感匹配以防万一。
    private static func mainLanguageBundle(for identifier: String) -> Bundle? {
        let wanted = identifier.lowercased()
        for name in Bundle.main.localizations where name.lowercased() == wanted {
            if let url = Bundle.main.url(forResource: name, withExtension: "lproj"),
                let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}
