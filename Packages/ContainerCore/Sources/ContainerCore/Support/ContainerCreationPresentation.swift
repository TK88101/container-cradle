import Foundation

/// 「创建族」失败态的用户文案：新建表单的字段错、create 提交失败、clone 提交失败。
///
/// 三组合一个 enum（而不是三个文件）：它们同属一个窗口语境，共用 `ContainerName` /
/// `RuntimeError` 的措辞，拆开只会让「同一个概念在两处说法不一致」变得更容易发生
/// ——同 `ContainerActionPresentation` 一个文件管全部 action 失败。
///
/// 住 core 的理由：**app target 没有测试 target**，文案 switch 放 view 里等于零测试。
public enum ContainerCreationPresentation {

    // MARK: - 表单字段错

    /// 穷尽 switch，无 `default`——`FieldError` 新增 case 时这里编译报错。
    public static func message(
        for error: ContainerCreationForm.FieldError,
        locale: Locale = .current
    ) -> String {
        switch error {
        case .name(let nameError):
            nameMessage(nameError, locale: locale)
        case .image:
            String(coreLocalized: "Enter an image reference, for example nginx:latest", locale: locale)
        case .spec(let specError):
            specMessage(specError, locale: locale)
        }
    }

    private static func nameMessage(_ error: ContainerNameError, locale: Locale) -> String {
        switch error {
        case .empty:
            String(coreLocalized: "Enter a container name", locale: locale)
        case .invalidFormat:
            String(
                coreLocalized: "Container names may only contain letters, digits, dots, dashes and underscores",
                locale: locale
            )
        }
    }

    private static func specMessage(_ error: ContainerCreationSpecError, locale: Locale) -> String {
        switch error {
        case .volumeMountPathNotAbsolute(let path):
            String(coreLocalized: "Mount path \(path) must start with a slash", locale: locale)
        case .volumeMountPathContainsColon(let path):
            String(coreLocalized: "Mount path \(path) must not contain a colon", locale: locale)
        case .duplicateVolumeMountPath(let path):
            String(coreLocalized: "Mount path \(path) is used more than once", locale: locale)
        case .invalidVolumeName(let name):
            String(coreLocalized: "\(name) is not a valid volume name", locale: locale)
        case .emptyEnvironmentKey:
            String(coreLocalized: "An environment variable name is empty", locale: locale)
        case .environmentKeyContainsEquals(let key):
            String(coreLocalized: "Environment variable name \(key) must not contain an equals sign", locale: locale)
        case .duplicateEnvironmentKey(let key):
            String(coreLocalized: "Environment variable \(key) is set more than once", locale: locale)
        }
    }

    // MARK: - create 提交失败

    /// 穷尽 switch，无 `default`——`Failure` 新增 case 时这里编译报错。
    public static func message(
        for failure: ContainerCreationStore.Failure,
        locale: Locale = .current
    ) -> String {
        switch failure {
        case .nameAlreadyExists(let id):
            String(coreLocalized: "A container named \(id.rawValue) already exists", locale: locale)
        case .precheckFailed(let error):
            String(
                coreLocalized:
                    "Could not check existing containers, so nothing was created: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                locale: locale
            )
        case .createFailed(let error):
            String(
                coreLocalized: "Create failed: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                locale: locale
            )
        case .startFailed(let id, let error):
            // **R-CMD 裁定（B 段 Plan §3.1）**：不按 `.operationFailed(reason)` 的内容
            // 嗅探「entrypoint not specified」之类再分支——那是本仓明令禁止的 R14 病，
            // 上游改一个词就静默失效，而测试还全绿。
            // 结构化文案替代之：说清「已建成 + 保留为已停止 + 技术详情原样」，
            // 用户据此知道**不用重建**，只需自己点一下启动。
            String(
                coreLocalized:
                    "Container \(id.rawValue) was created and kept as stopped; starting it failed: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                locale: locale
            )
        }
    }

    // MARK: - clone 模板加载失败

    /// `ContainerCloneStore.loadState == .failed` 的文案（T9.7 实施期补：Plan T9.5
    /// 漏列的第 5 组用户可见失败态）。住 core 的理由更硬一层：`RuntimeErrorPresentation`
    /// 刻意 internal，app 层**渲染不了**裸 `RuntimeError`——这不是分工偏好，是出不去。
    public static func message(
        forCloneLoadFailure error: RuntimeError,
        locale: Locale = .current
    ) -> String {
        String(
            coreLocalized:
                "Could not load the source container configuration: \(RuntimeErrorPresentation.detail(error, locale: locale))",
            locale: locale
        )
    }

    // MARK: - clone 提交失败

    /// 穷尽 switch，无 `default`——`SubmitFailure` 新增 case 时这里编译报错。
    public static func message(
        for failure: ContainerCloneStore.SubmitFailure,
        locale: Locale = .current
    ) -> String {
        switch failure {
        case .invalidName(let nameError):
            nameMessage(nameError, locale: locale)
        case .nameEqualsSource:
            // 与 `.nameAlreadyExists` 刻意不同措辞：那是「这名被别人占了」，
            // 这是「clone 必须换个名」——混为一谈会让用户改错东西。
            String(coreLocalized: "Give the clone a different name from the source container", locale: locale)
        case .nameAlreadyExists(let id):
            String(coreLocalized: "A container named \(id.rawValue) already exists", locale: locale)
        case .precheckFailed(let error):
            String(
                coreLocalized:
                    "Could not check existing containers, so nothing was created: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                locale: locale
            )
        case .createFailed(let error):
            String(
                coreLocalized: "Clone failed: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                locale: locale
            )
        }
    }
}
