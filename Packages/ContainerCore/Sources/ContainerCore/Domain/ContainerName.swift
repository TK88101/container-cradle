/// 用户**提议**的合法容器名——不等于已持久化的 identity（`ContainerID`，codex #7）。
///
/// fresh 创建与 clone 提交都要一个「新名」，两处共用同一套校验，故独立成类型：非法名构造不出来
/// （坑清单「边界值绕过硬约束」），UI 只负责把 `ContainerNameError` 翻成文案。
///
/// ## 逐字镜像上游 `ManagedContainer.nameValid`（1.4.1）
///
/// 上游 create 序列拒非法名的规则＝长度上限 + 正则（1.1.0 时在 `Utility.validEntityName`，
/// 1.4.1 删了它、规则收进 `ManagedContainer.nameValid` 并**新增** `count <= 63`——DNS label 上限）：
/// - `name.count <= 63`；
/// - `^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`——首字符字母数字、其余可含 `_.-`、**最少 2 字符**。
///
/// 这份镜像的一致性由 ContainerRuntime 的 `ContainerNameParityTests` 拿上游实现逐样本对照
/// （这里 import 不到上游，D1）——上游再改规则，那边会红。
///
/// - **不严于上游**：否则拒掉一个上游认可的名，用户明明能建却被 UI 挡（同 `ContainerID` 纪律）。
/// - **不松于上游**：否则把上游必拒的名放到 create 才炸，错得更晚、错误信息更糊。
/// - **不 trim**：上游校验的是原串，trim 会让 `" abc"` 静默通过而与上游漂移。
public struct ContainerName: Sendable, Equatable {

    public let value: String

    /// 上游 `ManagedContainer.nameValid` 的 `guard name.count <= 63`（同为 `String.count`）。
    public static let maxLength = 63

    public init(_ raw: String) throws(ContainerNameError) {
        guard !raw.isEmpty else { throw .empty }
        // 长度先于正则：超长且含非法字符时固定报 `.tooLong`，文案不随输入细节跳变。
        guard raw.count <= Self.maxLength else { throw .tooLong }

        // 与上游同款：从字符串模式构造 `Regex`（上游 `try Regex(pattern)`，逐次构造，非热路径）。
        // 模式是编译期已知的合法常量，故 `try!`——非法只可能是本行打错字，那是开发期崩、不是运行期
        // 分支。字符类里末尾的 `-`、class 内的 `.` 均为字面量（不需转义）。
        // 集合版 `wholeMatch(of:)` 不抛错、要求整串匹配 == 上游 `firstMatch` + `^…$`。
        let validName = try! Regex("[a-zA-Z0-9][a-zA-Z0-9_.-]+")
        guard raw.wholeMatch(of: validName) != nil else {
            throw .invalidFormat
        }

        self.value = raw
    }
}

/// 名字校验失败的域错误。`empty` 与 `invalidFormat` 分开，纯为给 UI 更贴切的文案
/// （「请输入名字」vs「含有不可用的字符」）——空串本身也过不了正则，先判空只是为了这条区分。
public enum ContainerNameError: Error, Equatable {
    case empty
    case invalidFormat
    /// 超过上游上限（字符都合法也会拒——所以不能塌进 `invalidFormat`，那条文案说的是字符）。
    case tooLong
}
