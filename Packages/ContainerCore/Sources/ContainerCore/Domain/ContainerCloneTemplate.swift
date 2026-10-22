/// clone「以此为模板新建」的预填数据——**纯 domain**（codex #1）。
///
/// 协议 `cloneTemplate(for:)` 的返回型：桥内 `SnapshotMapper` 从上游 `snapshot.configuration`
/// 提 image + env + 按挂载类型计数，装进这个类型返回。**app 永不碰 configuration**——完整配置仍住
/// 桥内白名单文件，只有摘要计数上浮成 domain（对比「domain 全往返」需给 domain 加 `Mount` 类型 +
/// 双向映射 + bind 宿主路径 domain 化重建，破坏面大得多；ruling 3 背书「复用 configuration 改 id」）。
///
/// env 每项是 `SecretString`：预填进 UI 时**不 reveal**（D2），编辑才瞬态解封（§3.6）。
public struct ContainerCloneTemplate: Sendable, Equatable {

    /// 只读继承——clone 不改镜像。
    public let image: ImageRef
    /// 源容器的 env（明文封在 `SecretString`）。`envOverride==nil` 时原样克隆，不进 UI。
    public let environment: [EnvironmentVariable]
    /// 挂载摘要计数——UI 显示「继承 N 个挂载：x volume / y bind / z tmpfs」，只读、不可编辑。
    public let mountSummary: MountSummary
    /// 源容器各网络附着的 DNS aliases 总数（上游 1.6.0 起有）。克隆**不复制** aliases（exact alias 全局唯一，带过去 create 必冲突）——
    /// 确认界面据此说一句「没复制」。**只有数量上浮**，alias 名字留桥内（Plan 2026-10-21 §2.3-3）。
    public let aliasCount: Int

    public init(image: ImageRef, environment: [EnvironmentVariable], mountSummary: MountSummary, aliasCount: Int) {
        self.image = image
        self.environment = environment
        self.mountSummary = mountSummary
        self.aliasCount = aliasCount
    }
}

/// 源容器挂载的分类计数（volume / bind / tmpfs）。**只有计数上浮成 domain**，宿主路径等细节留桥内。
public struct MountSummary: Sendable, Equatable {

    public let volumeCount: Int
    public let bindCount: Int
    public let tmpfsCount: Int

    public init(volumeCount: Int, bindCount: Int, tmpfsCount: Int) {
        self.volumeCount = volumeCount
        self.bindCount = bindCount
        self.tmpfsCount = tmpfsCount
    }

    public var total: Int { volumeCount + bindCount + tmpfsCount }
}
