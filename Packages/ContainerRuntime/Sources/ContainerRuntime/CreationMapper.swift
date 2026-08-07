import ContainerAPIClient
import ContainerCore
import ContainerResource
import Foundation

/// **domain `ContainerCreationSpec` → 上游 create 序列所需的 `Flags.*`。D1 的第 8 个落点。**
///
/// ## 纯映射，零副作用（§3.1）
///
/// 这里**只做结构转换**：spec 的字段 → `Flags.Process/Management/Resource/Registry/ImageFetch` +
/// id/image/arguments。**不打 XPC、不加载 `ContainerSystemConfig`、不调 `containerConfigFromFlags`**
/// ——那些副作用与它们的 `XPCTimeout` 住在 adapter（`LiveContainerRuntimeClient`）里。
/// 拆开的理由（codex #17）：`CreationMapper` 这个名字不该掩盖副作用；纯的部分才好逐字段断言。
///
/// ## `Flags.Management` 必须全字段 memberwise init（V2 真机教训）
///
/// 空 `Flags.Management()` 会让含 `@OptionGroup` 的 `dns` 停在**未初始化的 parsing 态**，
/// 读它触发 ArgumentParser fatal（spike V2 第一轮实崩在这）。全字段构造把每个属性钉死，
/// 取值＝上游 `@Option/@Flag` 声明的默认，`arch` 复用 CLI 同款 `Arch.hostArchitecture()`（零猜测）。
///
/// ## D2：唯一明文出口
///
/// env 明文只在 `serializeEnvironmentForCreate` 里现身（create 必须把 env 明文交给上游）。
/// 这是整个 `ContainerRuntime` 里唯一合法的明文取出点，由 `RuntimeBoundaryTests` 的
/// `plaintextExitsStayInBudget` 钉死预算＝1（该扫描按字面计数，注释里别再写带点的调用形态）。
enum CreationMapper {

    /// `Utility.containerConfigFromFlags` 的**纯**入参集合——运行时依赖
    /// （`containerSystemConfig` / `progressUpdate` / `log`）不在此，由 adapter 现场提供。
    ///
    /// `@unchecked Sendable`：本类型要跨 isolation 边界传进 `upstream.createContainer`（Live 用它
    /// 现建现用的 client、Fake 是 actor）。它是**一次构造、只读的值快照**，全部字段是 `String`/`[String]`
    /// 与上游 `Flags.*` 值结构（内部只有 String/Int/Bool/数组）——深不可变、无引用共享。上游把 `Flags.*`
    /// 声明成 `ParsableArguments` 却没顺手标 `Sendable`，编译器因此证不出来；这里由不可变性人工背书。
    struct CreateInputs: @unchecked Sendable {
        let id: String
        let image: String
        let arguments: [String]
        let process: Flags.Process
        let management: Flags.Management
        let resource: Flags.Resource
        let registry: Flags.Registry
        let imageFetch: Flags.ImageFetch
    }

    static func inputs(for spec: ContainerCreationSpec) -> CreateInputs {
        // 各字段取值＝上游声明默认（spike V2 全字段档，已真机验通）。
        let process = Flags.Process(
            cwd: nil,
            env: serializeEnvironmentForCreate(spec.environment),
            envFile: [],
            gid: nil,
            interactive: false,
            tty: false,
            uid: nil,
            ulimits: [],
            user: nil
        )
        // memory nil → 上游填默认（≥200 MiB），同 `container create` 不带 -m（non-goal：不暴露限额）。
        let resource = Flags.Resource(cpus: nil, memory: nil)
        let registry = Flags.Registry(scheme: "auto")
        let imageFetch = Flags.ImageFetch(maxConcurrentDownloads: 3)
        let dns = Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: [])
        // ★ 全字段 init（见类型文档「V2 真机教训」）：空 init 会让 dns 未初始化 → 读它 fatal。
        let management = Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: [],
            capDrop: [],
            cidfile: "",
            detach: false,
            dns: dns,
            dnsDisabled: false,
            entrypoint: nil,
            initImage: nil,
            kernel: nil,
            labels: [],
            mounts: [],
            // id 走 containerConfigFromFlags(id:) 参数，不走 --name（避免双写歧义）。
            name: nil,
            networks: [],
            os: "linux",
            platform: nil,
            publishPorts: [],
            publishSockets: [],
            readOnly: false,
            remove: false,
            rosetta: false,
            runtime: nil,
            ssh: false,
            shmSize: nil,
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: spec.volumeMounts.map(volumeArgument)
        )

        return CreateInputs(
            id: spec.name.value,
            image: spec.image.rawValue,
            // command/entrypoint 不暴露（non-goal）→ 空 arguments，依赖镜像自带 entrypoint/cmd。
            arguments: [],
            process: process,
            management: management,
            resource: resource,
            registry: registry,
            imageFetch: imageFetch
        )
    }

    /// 一条 volume 挂载 → 上游 `--volume` 字符串：`name:destination[:ro]`
    /// （已核 `Parser.volume`：命名卷走 2/3 段，第 3 段是逗号分隔选项，只读＝`ro`）。
    /// fresh 只建命名卷（`VolumeMount` 无宿主源、无 tmpfs）→ 不产生 bind/tmpfs 路径。
    ///
    /// **信赖 `ContainerCreationSpec` 已校验 `volumeName` 合法**（镜像上游命名卷正则）：
    /// 否则含 `/` 的名字在这里拼成 `name:dest` 会被上游当宿主 bind——值级绕过（codex T4-review）。
    /// mapper 不重复校验（校验单点在 domain，§3.1）。
    static func volumeArgument(for mount: VolumeMount) -> String {
        let base = "\(mount.volumeName):\(mount.containerPath)"
        return mount.readOnly ? "\(base):ro" : base
    }

    /// **D2 唯一明文出口。** create 必须把 env 明文（`key=value`）交给上游 `Flags.Process.env`。
    /// 除此之外 `ContainerRuntime` 里不该有任何明文取出——`plaintextExitsStayInBudget` 守此预算。
    ///
    /// **信赖 `ContainerCreationSpec` 已校验 key 不含 `=`**：否则 `A=B` + 值 `C` 拼成 `A=B=C`，
    /// 上游按首个 `=` 切 → key 变 `A`（codex T4-review）。校验单点在 domain，此处不重复。
    static func serializeEnvironmentForCreate(_ environment: [EnvironmentVariable]) -> [String] {
        environment.map { "\($0.key)=\($0.value.reveal())" }
    }

    /// server 端容器内存下限（200 MiB）。低于它 create 会被 server 拒——clone 复制 resources 时夹到此值。
    static let minimumCloneMemoryInBytes: UInt64 = 200 * 1024 * 1024

    /// clone 提交的**显式 sanitize**（§3.2 表 / codex #3 P0）。复用源 `configuration`（值类型，
    /// 本地 copy 不改源），只改**必须改**的，其余原样保留（ruling 3「复用 configuration 改 id」）：
    ///
    /// - `id` → 新名（clone 的本义）。
    /// - `networks` → **逐条重生，不清空**（codex Round 2 抓的功能回归）：`AttachmentConfiguration`
    ///   带**运行时分配的 macAddress** + 源 hostname，直接复制会 MAC 冲突（§2 已核）。但**清空成 `[]`
    ///   会让克隆体没网络**——fresh create 走 `containerConfigFromFlags` 时空 networks 会被上游
    ///   `getAttachmentConfigurations` 补成默认 builtin 附着（Utility.swift:330-334 已核），而 clone 走
    ///   `createFromConfiguration` 绕过那段、空数组原样持久化、bootstrap 只遍历 `config.networks` ⇒ 无连接。
    ///   所以保留每条附着的**网络名（拓扑）+ mtu**，只重置 per-instance 身份：`macAddress → nil`
    ///   （服务端重新分配，解冲突）、`hostname → 新 id`。源本就无网络（`--network none`）→ 保持空。
    /// - `publishedPorts` / `publishedSockets` → `[]`：host 侧端口/套接字绑定，两个容器抢同一个必冲突；
    ///   且是 non-goal（表单不提供）。
    /// - `resources` → 保留，`memoryInBytes` 夹到 ≥200 MiB 下限（server 最小值，防源值异常低导致 create 被拒）。
    /// - `creationDate` → 重置为传入的 `creationDate`（源的创建时间不该带给克隆体；now 由 adapter 现取，
    ///   保持本函数纯净可测）。
    /// - `envOverride != nil` → 用它替换 `initProcess.environment`（经 `serializeEnvironmentForCreate`，
    ///   D2 唯一明文出口；nil 则原样克隆源 env，不进 UI）。
    ///
    /// 其余字段（image / mounts / labels / sysctls / dns / rosetta / platform / initProcess 其余 /
    /// runtimeHandler / virtualization / ssh / readOnly / useInit / capAdd / capDrop / shmSize /
    /// stopSignal）**原样保留**。
    ///
    /// ## 第二密钥路径（codex #6）
    ///
    /// `configuration.initProcess.environment` 是明文 `[String]`，**不经 `SecretString`**——D2 的
    /// reveal 扫描抓不到它。故这段代码（及 adapter 的 clone 分支）**绝不 log / print / debug
    /// configuration**，由 `RuntimeBoundaryTests` 的源码扫描守（T7）。
    static func sanitizeForClone(
        _ source: ContainerConfiguration,
        newID: String,
        envOverride: [EnvironmentVariable]?,
        creationDate: Date
    ) -> ContainerConfiguration {
        var config = source
        config.id = newID
        // networks：保留网络名 + mtu（拓扑/连接），重置 per-instance 身份（MAC → nil 让服务端重分配、
        // hostname → 新 id）。**不清空**——清空会让克隆体无网络（见类型文档 codex Round 2 记录）。
        config.networks = source.networks.map { attachment in
            AttachmentConfiguration(
                network: attachment.network,
                options: AttachmentOptions(
                    hostname: newID,
                    macAddress: nil,
                    mtu: attachment.options.mtu
                )
            )
        }
        config.publishedPorts = []
        config.publishedSockets = []
        config.resources.memoryInBytes = max(config.resources.memoryInBytes, minimumCloneMemoryInBytes)
        config.creationDate = creationDate
        if let envOverride {
            config.initProcess.environment = serializeEnvironmentForCreate(envOverride)
        }
        return config
    }
}
