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
        case .tooLong:
            String(coreLocalized: "Container names can be at most \(ContainerName.maxLength) characters", locale: locale)
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
            // 超时 ≠ 失败、本 App 挡下没发出 ≠ 失败：不能说 "Create failed"（Day 24–25）。
            RuntimeErrorPresentation.notFailedCreationText(error, locale: locale)
                ?? String(
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

    // MARK: - 提交进行中（Day 25）

    /// 提交满这么久才提示「仍在进行」：热路径一秒内就回来，30 s 足以说明是冷启动那种慢（Day 24 实测 257 s）。
    static let stillWorkingDelay: TimeInterval = 30

    /// 新建 / 克隆窗口按钮下方的进行中提示（Plan 2026-10-22 §2.4）。`now` 只是渲染 tick；`submittedAt` 才是时间事实。
    /// `submittedAt == nil`（不在提交中）⇒ 一律 nil——store 的不变式是 `isBusy ⇔ submittedAt != nil`。
    public static func progressNote(
        isConfirming: Bool,
        submittedAt: Date?,
        now: Date,
        locale: Locale = .current
    ) -> String? {
        guard let submittedAt else { return nil }
        if isConfirming {
            return String(coreLocalized: "The runtime has not answered yet. Waiting for the result…", locale: locale)
        }
        guard now.timeIntervalSince(submittedAt) >= stillWorkingDelay else { return nil }
        return String(
            coreLocalized: "Still working. The first container after a runtime update can take a few minutes.",
            locale: locale
        )
    }

    // MARK: - clone 确认：aliases 没复制

    /// 源容器有 DNS aliases 时，确认界面多一行说明克隆不会带上它们（Plan 2026-10-21 §2.3-3）。不点名：template 里只有数量。
    public static func cloneAliasNote(for template: ContainerCloneTemplate, locale: Locale = .current) -> String? {
        guard template.aliasCount > 0 else { return nil }
        return String(coreLocalized: "DNS aliases are not copied to the clone", locale: locale)
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
            // 同 create：结果未定 / 没发出都不是失败。
            RuntimeErrorPresentation.notFailedCreationText(error, locale: locale)
                ?? String(
                    coreLocalized: "Clone failed: \(RuntimeErrorPresentation.detail(error, locale: locale))",
                    locale: locale
                )
        }
    }
}
