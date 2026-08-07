/// 「从零新建一个容器」的完整意图——不可变，非法组合构造不出来（坑清单「边界值绕过硬约束」）。
///
/// 字段刻意只有名字 / 镜像 / volume 挂载 / env：**无 memory/cpu/command/entrypoint**——那些是
/// non-goal，不暴露则上游填默认（memory ≥200 MiB 由上游保证，command 依赖镜像自带 entrypoint）。
///
/// ## 校验落在此类型（非 UI）
///
/// - 校验集中在此类型（fresh 创建的校验单点）：容器路径绝对、容器路径不重复、env key 非空且不重复。
///   其中**路径不重复 / key 不重复是真·跨条目**——只有这里看得到整张列表；
///   路径绝对 / key 非空是单条目属性，一并归此处集中校验（`VolumeMount` 是被聚合的纯三元组，不自证）。
/// - **名字唯一性不在这里**：init 看不到别的容器；提交前由桥层显式 `get(name)` 命中即拒
///   （靠存在性、不嗅错误码——R14）。此类型只保证「单个 spec 自洽」。
/// - env 值全程 `SecretString`：构建 spec **不 reveal**，明文只在 `CreationMapper` 的
///   `serializeEnvironmentForCreate`（D2 唯一出口）里现身。
public struct ContainerCreationSpec: Sendable, Equatable {

    public let name: ContainerName
    public let image: ImageRef
    public let volumeMounts: [VolumeMount]
    public let environment: [EnvironmentVariable]

    public init(
        name: ContainerName,
        image: ImageRef,
        volumeMounts: [VolumeMount],
        environment: [EnvironmentVariable]
    ) throws(ContainerCreationSpecError) {
        // volume 名逐字镜像上游 `VolumeStorage.volumeNamePattern`：`^[A-Za-z0-9][A-Za-z0-9_.-]*$` + ≤255。
        // 不校验的话，含 `/` 的名字（`data/../etc`）会被上游 `Parser.volume` 当**宿主 bind 挂载**、
        // 空名当**匿名卷**——静默绕开「fresh 只能建命名卷」的类型不变式（codex T4-review）。
        // `*` 量词（非 `+`）＝允许单字符，同上游；不严于/不松于上游（同 `ContainerName` 纪律）。
        // 模式是编译期已知的合法常量，故 `try!`（同 `ContainerName`：非法只可能是本行打错字，
        // 属开发期崩、非运行期分支）；逐次构造 == 上游 `try Regex(pattern)`，create 非热路径。
        let validVolumeName = try! Regex("[A-Za-z0-9][A-Za-z0-9_.-]*")
        var seenPaths = Set<String>()
        for mount in volumeMounts {
            guard mount.volumeName.count <= 255,
                  mount.volumeName.wholeMatch(of: validVolumeName) != nil else {
                throw .invalidVolumeName(mount.volumeName)
            }
            guard mount.containerPath.hasPrefix("/") else {
                throw .volumeMountPathNotAbsolute(mount.containerPath)
            }
            // `--volume name:dest[:opt]` 以 `:` 分隔：dest 里的 `:` 会被上游 `Parser.volume` 切成
            // 挂载选项（`/data:ro` → dest `/data` + 选项 `ro`）或 4 段非法（codex T4-review）。
            // 简写表示法表达不了含 `:` 的路径 → 拒（同 volumeName/env-key 的分隔符纪律）。
            guard !mount.containerPath.contains(":") else {
                throw .volumeMountPathContainsColon(mount.containerPath)
            }
            guard seenPaths.insert(mount.containerPath).inserted else {
                throw .duplicateVolumeMountPath(mount.containerPath)
            }
        }

        var seenKeys = Set<String>()
        for variable in environment {
            guard !variable.key.isEmpty else {
                throw .emptyEnvironmentKey
            }
            // key 含 `=` → 序列化成 `key=value` 后被上游按首个 `=` 切成别的 key（codex T4-review）。
            // 只挡真正会坏序列化的 `=`，不额外收紧 env 名字符集（上游自己也不收）。
            guard !variable.key.contains("=") else {
                throw .environmentKeyContainsEquals(variable.key)
            }
            guard seenKeys.insert(variable.key).inserted else {
                throw .duplicateEnvironmentKey(variable.key)
            }
        }

        self.name = name
        self.image = image
        self.volumeMounts = volumeMounts
        self.environment = environment
    }
}

/// spec 组装失败的域错误。关联值带上冒犯项（路径 / 名字 / key），供 UI 指名报错。
public enum ContainerCreationSpecError: Error, Equatable {
    case volumeMountPathNotAbsolute(String)
    /// 容器路径含 `:`——`--volume name:dest[:opt]` 用 `:` 分隔，dest 里的 `:` 会被上游切成挂载选项。
    case volumeMountPathContainsColon(String)
    case duplicateVolumeMountPath(String)
    /// volume 名不是合法命名卷名（空、含 `/`、含非法字符）——否则被上游当宿主 bind / 匿名卷。
    case invalidVolumeName(String)
    case emptyEnvironmentKey
    /// env key 含 `=`——序列化成 `key=value` 后会被上游按首个 `=` 切成别的 key。
    case environmentKeyContainsEquals(String)
    case duplicateEnvironmentKey(String)
}
