import Testing

@testable import ContainerCore

/// T1（Day 16）：`ContainerName` / `VolumeMount` / `ContainerCreationSpec` 的校验矩阵。
///
/// 校验单点归 domain 类型（非 UI 拦）——非法值构造不出来（坑清单「边界值绕过硬约束」）。
/// `ContainerName` 的正则**逐字镜像上游** `Utility.validEntityName`
/// (`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`，已核 Utility.swift:60)：既不严于上游（否则拒掉上游认可的名，
/// 同 `ContainerID` 的纪律），也不松于上游（否则把上游必拒的名放到 create 才炸，错得更晚更糊）。
@Suite("ContainerCreationSpec 校验矩阵")
struct ContainerCreationSpecTests {

    // 合成 env 值，非真实密钥。
    static let secretValue = "sk-Ab3dEf6hIj9lMn2pQr5tUv8xYz1cDe4fGh7jKl0mNo="

    // MARK: - ContainerName（镜像上游 validEntityName）

    @Test("合法名放行", arguments: [
        "ab",                  // 最短合法：两字符
        "A9",
        "my-container_1.0",
        "nginx",
        "web.app-01",
    ])
    func acceptsValidNames(raw: String) throws {
        let name = try ContainerName(raw)
        #expect(name.value == raw)
    }

    @Test("空名抛 .empty")
    func rejectsEmptyName() {
        #expect(throws: ContainerNameError.empty) {
            try ContainerName("")
        }
    }

    /// 上游正则要求 `[first][rest]+` → **最少 2 字符**；单字符是上游会拒的名，早拒好过 create 才炸。
    @Test("单字符不合法（上游最少 2 字符）")
    func rejectsSingleCharacter() {
        #expect(throws: ContainerNameError.invalidFormat) {
            try ContainerName("a")
        }
    }

    @Test("首字符非字母数字不合法", arguments: ["_abc", ".abc", "-abc"])
    func rejectsInvalidFirstCharacter(raw: String) {
        #expect(throws: ContainerNameError.invalidFormat) {
            try ContainerName(raw)
        }
    }

    /// 空格不在字符类里 → 无论内部空格还是首尾空格都必须被拒。
    /// **刻意不 trim**：上游 `validEntityName` 校验的是原串，trim 会让 " abc" 静默通过而与上游漂移。
    @Test("含空格不合法", arguments: ["ab c", " abc", "abc ", "a b"])
    func rejectsNamesWithSpaces(raw: String) {
        #expect(throws: ContainerNameError.invalidFormat) {
            try ContainerName(raw)
        }
    }

    @Test("非法字符不合法", arguments: ["ab/cd", "ab:cd", "ab@cd", "ab$cd"])
    func rejectsIllegalCharacters(raw: String) {
        #expect(throws: ContainerNameError.invalidFormat) {
            try ContainerName(raw)
        }
    }

    // MARK: - 镜像空值由 ImageRef 类型挡（spec 不接受可空镜像）

    @Test("空镜像在 ImageRef 层被挡（构造不出）")
    func emptyImageRejectedByType() {
        #expect(ImageRef("") == nil)
        #expect(ImageRef("   ") == nil)
    }

    // MARK: - ContainerCreationSpec：volume 挂载校验

    @Test("合法 spec 保留全部字段")
    func buildsValidSpec() throws {
        let spec = try ContainerCreationSpec(
            name: ContainerName("web-01"),
            image: #require(ImageRef("nginx:latest")),
            volumeMounts: [
                VolumeMount(volumeName: "data", containerPath: "/var/data", readOnly: false),
                VolumeMount(volumeName: "conf", containerPath: "/etc/app", readOnly: true),
            ],
            environment: [
                EnvironmentVariable(key: "NODE_ENV", value: SecretString("production")),
            ]
        )

        #expect(spec.name.value == "web-01")
        #expect(spec.image.rawValue == "nginx:latest")
        #expect(spec.volumeMounts.count == 2)
        #expect(spec.volumeMounts[1].readOnly == true)
        #expect(spec.environment.count == 1)
    }

    @Test("非绝对容器路径被拒")
    func rejectsRelativeContainerPath() throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.volumeMountPathNotAbsolute("var/data")) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [VolumeMount(volumeName: "d", containerPath: "var/data", readOnly: false)],
                environment: []
            )
        }
    }

    @Test("重复容器路径被拒")
    func rejectsDuplicateContainerPath() throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.duplicateVolumeMountPath("/data")) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [
                    VolumeMount(volumeName: "a", containerPath: "/data", readOnly: false),
                    VolumeMount(volumeName: "b", containerPath: "/data", readOnly: true),
                ],
                environment: []
            )
        }
    }

    // MARK: - ContainerCreationSpec：volume 名校验（codex T4-review：值级 bind 绕过）

    /// ★ 值级不变式：`VolumeMount` 是纯三元组，字段集守不住 `volumeName` **的取值**。
    /// 含 `/` 的名字会被上游 `Parser.volume` 当**宿主 bind 挂载**、空名当**匿名卷**——
    /// 两者都静默绕开「fresh 只能建命名卷」的不变式（codex 在 T4 mapper 上抓到）。
    /// 校验落在 spec（§3.1 校验单点），逐字镜像上游 `VolumeStorage.volumeNamePattern`。
    @Test("volume 名含路径语法被拒（否则被上游当宿主 bind）", arguments: ["/etc", "a/b", "./x", "../y"])
    func rejectsVolumeNameWithPathSyntax(raw: String) throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.invalidVolumeName(raw)) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [VolumeMount(volumeName: raw, containerPath: "/data", readOnly: false)],
                environment: []
            )
        }
    }

    @Test("空 volume 名被拒（否则被上游当匿名卷）")
    func rejectsEmptyVolumeName() throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.invalidVolumeName("")) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [VolumeMount(volumeName: "", containerPath: "/data", readOnly: false)],
                environment: []
            )
        }
    }

    @Test("合法 volume 名放行（含单字符——上游 `*` 量词允许，别严于上游）", arguments: ["a", "data", "my-vol_1.2"])
    func acceptsValidVolumeNames(raw: String) throws {
        let image = try #require(ImageRef("nginx"))
        let spec = try ContainerCreationSpec(
            name: ContainerName("web"),
            image: image,
            volumeMounts: [VolumeMount(volumeName: raw, containerPath: "/data", readOnly: false)],
            environment: []
        )
        #expect(spec.volumeMounts[0].volumeName == raw)
    }

    /// ★ 容器路径含 `:` 会静默改义：`--volume vol:/data:ro` 被上游按 `:` 切 → dest=`/data` + 选项 `ro`
    /// （静默变只读），或 `vol:/data:x:ro` 4 段直接非法（codex T4-review round 2）。
    /// `--volume` 简写以 `:` 分隔，dest 里的 `:` 在此表示法下不可表达 → domain 拒之（校验单点）。
    @Test("容器路径含 `:` 被拒（否则被上游切成挂载选项）", arguments: ["/data:ro", "/a:b", "/x:"])
    func rejectsContainerPathWithColon(raw: String) throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.volumeMountPathContainsColon(raw)) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [VolumeMount(volumeName: "vol", containerPath: raw, readOnly: false)],
                environment: []
            )
        }
    }

    // MARK: - ContainerCreationSpec：env 校验

    @Test("空 env key 被拒")
    func rejectsEmptyEnvKey() throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.emptyEnvironmentKey) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [],
                environment: [EnvironmentVariable(key: "", value: SecretString("x"))]
            )
        }
    }

    @Test("重复 env key 被拒")
    func rejectsDuplicateEnvKey() throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.duplicateEnvironmentKey("API_KEY")) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [],
                environment: [
                    EnvironmentVariable(key: "API_KEY", value: SecretString(Self.secretValue)),
                    EnvironmentVariable(key: "API_KEY", value: SecretString("dup")),
                ]
            )
        }
    }

    /// ★ env key 含 `=` 会静默改义：key `A=B` + 值 `C` 序列化成 `A=B=C`，上游按首个 `=` 切
    /// → key 变成 `A`（codex T4-review）。domain 原本只挡空/重复 key，放这个进去会建错环境。
    /// 只挡 `=`（序列化真会坏的那个字符），不额外收紧——别严于上游（同 ContainerName 纪律）。
    @Test("env key 含 `=` 被拒（否则序列化后被上游切成别的 key）", arguments: ["A=B", "=", "K=", "a=b=c"])
    func rejectsEnvKeyContainingEquals(rawKey: String) throws {
        let image = try #require(ImageRef("nginx"))
        #expect(throws: ContainerCreationSpecError.environmentKeyContainsEquals(rawKey)) {
            try ContainerCreationSpec(
                name: ContainerName("web"),
                image: image,
                volumeMounts: [],
                environment: [EnvironmentVariable(key: rawKey, value: SecretString("v"))]
            )
        }
    }

    @Test("env 值全程 SecretString，构建 spec 不 reveal")
    func envValueStaysRedactedInSpec() throws {
        let image = try #require(ImageRef("nginx"))
        let spec = try ContainerCreationSpec(
            name: ContainerName("web"),
            image: image,
            volumeMounts: [],
            environment: [EnvironmentVariable(key: "TOKEN", value: SecretString(Self.secretValue))]
        )

        #expect("\(spec.environment[0].value)" == "<redacted>")
    }

    // MARK: - codex #16：fresh spec 无法表达 bind / tmpfs（类型级不对称守卫）

    /// fresh 创建**只能**表达 named volume 挂载：`VolumeMount` 的存储字段恰为
    /// `{volumeName, containerPath, readOnly}`——没有宿主源路径（bind）、没有 tmpfs 标记。
    /// 于是「fresh 表单能建 bind/tmpfs」这件事在**类型上**表达不出来（non-goal，需宿主路径选择器）。
    ///
    /// 本测试用反射钉死字段集合：将来谁给 `VolumeMount` 加一个 `hostPath`/`source`/`type` 字段，
    /// 就会**静默**打开 fresh 建 bind/tmpfs 的口子——这条断言让那次改动立刻变红。
    @Test("VolumeMount 字段恰为 named-volume 三元组（挡 bind/tmpfs 上浮）")
    func volumeMountCannotExpressBindOrTmpfs() {
        let mount = VolumeMount(volumeName: "data", containerPath: "/data", readOnly: false)
        let fields = Set(Mirror(reflecting: mount).children.compactMap(\.label))
        #expect(fields == ["volumeName", "containerPath", "readOnly"])
    }
}
