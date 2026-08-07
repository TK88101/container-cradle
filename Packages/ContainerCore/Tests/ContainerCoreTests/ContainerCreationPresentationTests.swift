import Foundation
import Testing

@testable import ContainerCore

/// T9.5：「创建族」三组失败态的用户文案（form 字段错 / create 提交失败 / clone 提交失败）。
///
/// 住 core 的理由同 `ContainerActionPresentation`：**app target 没有测试 target**，
/// 文案 switch 写进 view 就等于零测试（坑清单「可测性不是洁癖」）。
///
/// ## 插值 key 的唯一守卫（B 段 codex #5）
///
/// `Scripts/check-localization.sh` 第 ② 段只抽**纯字面** `coreLocalized: "…"`
/// （脚本自己的注释已承认无法从源码还原插值 key），第 ③ 段的跨 lproj key-set 等值 diff
/// 对「三语**都**漏同一个插值 key」也是瞎的。→ 含插值的 key 必须在这里有
/// **zh-Hans 非 key 回显**的断言，否则漏译会静默通过全部自动检查。
@Suite("ContainerCreationPresentation 创建族失败文案")
struct ContainerCreationPresentationTests {

    private let en = Locale(identifier: "en")
    private let zh = Locale(identifier: "zh-Hans")

    private func id(_ raw: String) throws -> ContainerID { try #require(ContainerID(raw)) }

    // MARK: - form 字段错

    private var allFieldErrors: [ContainerCreationForm.FieldError] {
        [
            .name(.empty),
            .name(.invalidFormat),
            .image,
            .spec(.volumeMountPathNotAbsolute("data")),
            .spec(.volumeMountPathContainsColon("/a:b")),
            .spec(.duplicateVolumeMountPath("/data")),
            .spec(.invalidVolumeName("bad name")),
            .spec(.emptyEnvironmentKey),
            .spec(.environmentKeyContainsEquals("A=B")),
            .spec(.duplicateEnvironmentKey("K")),
        ]
    }

    @Test("FieldError：每个 case 非空且互不相同（防复制粘贴漏改）")
    func fieldErrorsDistinct() {
        let messages = allFieldErrors.map { ContainerCreationPresentation.message(for: $0, locale: en) }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
    }

    @Test("FieldError：带参数的 case 文案里含那个参数（用户要知道是哪一行错了）")
    func fieldErrorsNameTheOffendingValue() {
        #expect(
            ContainerCreationPresentation.message(for: .spec(.duplicateVolumeMountPath("/data")), locale: en)
                .contains("/data")
        )
        #expect(
            ContainerCreationPresentation.message(for: .spec(.duplicateEnvironmentKey("K")), locale: en)
                .contains("K")
        )
        #expect(
            ContainerCreationPresentation.message(for: .spec(.invalidVolumeName("bad name")), locale: en)
                .contains("bad name")
        )
    }

    @Test("FieldError：zh-Hans 全部有译文（非 key 回显）——插值 key 的唯一守卫")
    func fieldErrorsTranslatedToSimplifiedChinese() {
        for error in allFieldErrors {
            let localized = ContainerCreationPresentation.message(for: error, locale: zh)
            let english = ContainerCreationPresentation.message(for: error, locale: en)
            #expect(localized != english, "未翻译（key 回显）：\(english)")
        }
    }

    // MARK: - create 提交失败

    private func allCreationFailures() throws -> [ContainerCreationStore.Failure] {
        [
            .nameAlreadyExists(try id("web")),
            .precheckFailed(.runtimeUnavailable),
            .createFailed(.operationFailed(reason: "boom")),
            .startFailed(try id("web"), .operationFailed(reason: "exit status 125")),
        ]
    }

    @Test("Failure：每个 case 非空且互不相同")
    func creationFailuresDistinct() throws {
        let messages = try allCreationFailures().map {
            ContainerCreationPresentation.message(for: $0, locale: en)
        }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
    }

    /// **R-CMD 裁定（Plan §3.1）**：不按 `.operationFailed(reason)` 的内容做子串嗅探分支
    /// （那是本仓明令禁止的 R14 病，上游改一个词就静默失效且测试全绿）。
    /// 取而代之是结构化文案——必须同时说清三件事：
    /// ① 容器**已经建成**；② 它**保留为已停止**（别以为要重建）；③ 技术详情原样。
    @Test("startFailed：含容器 id、含「已创建但保留为已停止」语义、技术详情原样透传")
    func startFailedIsStructured() throws {
        let message = ContainerCreationPresentation.message(
            for: .startFailed(try id("web"), .operationFailed(reason: "exit status 125")),
            locale: en
        )
        #expect(message.contains("web"))                 // 是哪个容器
        #expect(message.contains("exit status 125"))     // 技术详情不翻译、可搜索
        // 保留态语义：英文文案里必须出现 stopped（用户据此知道不用重建）
        #expect(message.lowercased().contains("stopped"))
    }

    @Test("nameAlreadyExists：文案含冲突的容器名")
    func nameClashNamesTheContainer() throws {
        #expect(
            ContainerCreationPresentation.message(
                for: ContainerCreationStore.Failure.nameAlreadyExists(try id("web")),
                locale: en
            ).contains("web")
        )
    }

    @Test("Failure：zh-Hans 全部有译文（非 key 回显）")
    func creationFailuresTranslated() throws {
        for failure in try allCreationFailures() {
            let localized = ContainerCreationPresentation.message(for: failure, locale: zh)
            let english = ContainerCreationPresentation.message(for: failure, locale: en)
            #expect(localized != english, "未翻译（key 回显）：\(english)")
        }
    }

    // MARK: - clone 提交失败

    private func allCloneFailures() throws -> [ContainerCloneStore.SubmitFailure] {
        [
            .invalidName(.empty),
            .invalidName(.invalidFormat),
            .nameEqualsSource,
            .nameAlreadyExists(try id("taken")),
            .precheckFailed(.runtimeUnavailable),
            .createFailed(.operationFailed(reason: "boom")),
        ]
    }

    @Test("SubmitFailure：每个 case 非空且互不相同")
    func cloneFailuresDistinct() throws {
        let messages = try allCloneFailures().map {
            ContainerCreationPresentation.message(for: $0, locale: en)
        }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
    }

    /// clone 的 `.nameEqualsSource` 与 create 的 `.nameAlreadyExists` 是**不同处境**：
    /// 前者是「你得换个名」，后者是「这名被别人占了」。文案混为一谈会让用户改错东西。
    @Test("nameEqualsSource 与 nameAlreadyExists 文案不同")
    func cloneNameErrorsAreDistinguishable() throws {
        let sameAsSource = ContainerCreationPresentation.message(for: .nameEqualsSource, locale: en)
        let taken = ContainerCreationPresentation.message(
            for: ContainerCloneStore.SubmitFailure.nameAlreadyExists(try id("taken")),
            locale: en
        )
        #expect(sameAsSource != taken)
    }

    @Test("SubmitFailure：zh-Hans 全部有译文（非 key 回显）")
    func cloneFailuresTranslated() throws {
        for failure in try allCloneFailures() {
            let localized = ContainerCreationPresentation.message(for: failure, locale: zh)
            let english = ContainerCreationPresentation.message(for: failure, locale: en)
            #expect(localized != english, "未翻译（key 回显）：\(english)")
        }
    }

    // MARK: - clone 模板加载失败（T9.7 实施期补）

    /// Plan T9.5 只列了 4 组失败态，漏了 `ContainerCloneStore.loadState.failed`——
    /// 而 `RuntimeErrorPresentation` 刻意 internal，app 层**渲染不了**裸 `RuntimeError`，
    /// 文案必须住 core（同一条「app 零测试」纪律）。T9.7 接线时补于此。
    @Test("CloneLoadFailure：非空、技术详情原样透传、zh-Hans 有译文（插值 key 守卫）")
    func cloneLoadFailureMessage() {
        let english = ContainerCreationPresentation.message(
            forCloneLoadFailure: .operationFailed(reason: "boom"),
            locale: en
        )
        #expect(!english.isEmpty)
        #expect(english.contains("boom"))

        let localized = ContainerCreationPresentation.message(
            forCloneLoadFailure: .operationFailed(reason: "boom"),
            locale: zh
        )
        #expect(localized != english, "未翻译（key 回显）：\(english)")
    }
}
