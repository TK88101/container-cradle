import Observation

/// 「新建容器」表单的草稿态 + 校验（Day 16 T9.1，能力 A）。**纯逻辑住 core、可测**——
/// 草稿字段的收集、把分散的 domain init 错误聚合成**按字段定位**的形态，都是判断逻辑，
/// 放 view 里就没人守（坑清单「可测性不是洁癖」）。
///
/// ## 职责边界：只组装、不提交
///
/// form 只做「收集草稿 + `buildSpec()` 校验组装」，**不做提交**——提交仍走已测的
/// `ContainerCreationStore.submit(spec)`（T3）。form 若再包一层异步提交 = 重复且引入新的
/// 重入面。view（B 段）编排：`buildSpec()` 成功 → `store.submit(spec)`。故 form **无 `async`、
/// 无单飞令牌**（那些是 store 的事）。
///
/// ## env 明文入口纪律（D2 / codex #18）
///
/// `environment` 存 `[EnvironmentVariable]`（值 `SecretString`）——明文由 **view 层**（B 段）在
/// `SecretString(plaintext)` 构造点包入后才进 form；form 内**零 `reveal()`**（只读 key 做校验，
/// 值原样透传给 `ContainerCreationSpec`）。长寿命 core 态永不含明文 `String`。
@MainActor
@Observable
public final class ContainerCreationForm {

    /// 容器名草稿（原始输入，校验推迟到 `buildSpec`）。
    public var name: String = ""

    /// 镜像 ref 草稿（原始输入）。
    public var imageReference: String = ""

    /// volume 挂载草稿行。`VolumeMount` 是被聚合的纯三元组，不自证——跨条目校验（路径绝对/不重复/
    /// 名字合法/不含冒号）由 `ContainerCreationSpec.init` 集中做（fresh 校验单点）。
    public var volumeMounts: [VolumeMount] = []

    /// env 草稿行。值已是 `SecretString`（脱敏）——key 的校验（非空/不含 `=`/不重复）由 spec.init 做。
    public var environment: [EnvironmentVariable] = []

    public init() {}

    /// 把四个草稿字段全部清回初始值。
    ///
    /// 住 core 而不是让 view 逐字段清（B 段 codex #6）：view 里手抄一遍赋值必然会漏掉
    /// **数组字段**（漏清 `volumeMounts` / `environment` 的后果是下一个新建的容器
    /// 悄悄继承了上一个的挂载与 env——后者还是密钥）。放这里才有测试守着。
    /// 将来给 form 加第五个字段时，`ContainerCreationFormTests` 的逐字段断言会逼着这里同步。
    public func reset() {
        name = ""
        imageReference = ""
        volumeMounts = []
        environment = []
    }

    /// 组装失败——按字段定位，UI 据此指名报错（哪个字段红）。首错优先：name → image → spec。
    public enum FieldError: Error, Sendable, Equatable {
        /// 名字空 / 格式非法（来自 `ContainerName.init`）。
        case name(ContainerNameError)
        /// 镜像 ref 空或全空白（`ImageRef(_:)` 返回 nil）。
        case image
        /// volume / env 跨条目校验（来自 `ContainerCreationSpec.init`）。
        case spec(ContainerCreationSpecError)
    }

    /// 纯函数：不 mutate、不 `await`。UI 既用它做实时校验预览（读 `.failure` 那一侧指名报错），
    /// 也用它取提交用的 spec（`.success`）。首错优先——与 domain init「第一个非法即抛」一致，
    /// UI 逐字段修复。
    public func buildSpec() -> Result<ContainerCreationSpec, FieldError> {
        let containerName: ContainerName
        do {
            containerName = try ContainerName(name)
        } catch {
            return .failure(.name(error))
        }

        guard let image = ImageRef(imageReference) else {
            return .failure(.image)
        }

        do {
            let spec = try ContainerCreationSpec(
                name: containerName,
                image: image,
                volumeMounts: volumeMounts,
                environment: environment
            )
            return .success(spec)
        } catch {
            return .failure(.spec(error))
        }
    }
}
