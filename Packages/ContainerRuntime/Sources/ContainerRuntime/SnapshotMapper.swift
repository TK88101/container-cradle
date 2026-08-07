import ContainerCore
import ContainerResource

/// **上游 `ContainerSnapshot` → domain `Container`。上游改字段，只有这个文件编译不过。**
///
/// D1 的兑现点：整个仓库里只有 4 个文件认识上游类型，这是其中之一。
enum SnapshotMapper {

    /// ## 映射不出来 → **整个 `list()` 失败**，不静默跳过那一个容器
    ///
    /// 顺手的写法是 `compactMap`：坏的容器丢掉，好的照常返回。**那是本 App 最坏的失败模式**——
    /// 被丢掉的容器从列表里**静默消失**，supervisor 因此不会去拉它，
    /// 而一切看起来完全正常（没有报错、没有红灯、菜单栏一切如常）。
    /// 那正是这个 App 存在的理由失效的样子，且没有任何东西会告诉用户。
    ///
    /// 整体失败则相反：可见（降级 UI）、可重试（`.transient` 走退避）、会被修。
    /// **失败关闭，不失败开放。**
    static func map(_ snapshot: ContainerSnapshot) throws(MappingError) -> Container {
        guard let id = ContainerID(snapshot.id) else {
            throw .invalidID(raw: snapshot.id)
        }

        let reference = snapshot.configuration.image.reference
        guard let image = ImageRef(reference) else {
            throw .invalidImage(containerID: snapshot.id, raw: reference)
        }

        return Container(
            id: id,
            image: image,
            state: state(from: snapshot.status),
            environment: environment(from: snapshot.configuration.initProcess.environment)
        )
    }

    /// **穷尽 `switch`，不用 rawValue 转换。**
    ///
    /// `ContainerState(rawValue: upstream.rawValue)` 看着聪明，实则是静默耦合：
    /// 上游哪天把 `stopping` 改叫 `terminating`，那行代码**照样编译**，只是运行时开始返回 `nil`——
    /// 一个状态悄悄消失，而不是一个编译错误。
    ///
    /// 写成穷尽 switch，上游增删 case → **构建当场炸**。那正是我们要的（R1）。
    static func state(from status: RuntimeStatus) -> ContainerState {
        switch status {
        case .unknown: .unknown
        case .stopped: .stopped
        case .running: .running
        case .stopping: .stopping
        }
    }

    /// 上游的 `environment` 是 `[String]`（元素形如 `"KEY=VALUE"`），不是字典（已核实源码）。
    ///
    /// ## 这里是 D2 的落点：值一律变成 `SecretString`
    ///
    /// 实测本机 `open-connector` 的 env 里有 **3 个 44 字符明文密钥**。映射成 `SecretString` 之后，
    /// 「把整个 `Container` 插进日志」这个最顺手的写法，产出的也是 `<redacted>`——
    /// 不是因为谁记得打码，而是因为明文根本走不出来。
    ///
    /// **畸形条目（无 `=`、key 为空）静默丢弃**，与「映射失败要整体炸」不矛盾：
    /// 丢一条环境变量不会让容器从列表里消失，supervisor 照常拉它；
    /// 而为一条 `""` 把整个列表判失败，才是真的因小失大。上游无 schema 承诺，
    /// mapper 必须吞得下意外输入（R1）。
    static func environment(from raw: [String]) -> [EnvironmentVariable] {
        raw.compactMap(EnvironmentVariable.init(parsing:))
    }

    /// clone「以此为模板」的预填提取（T6.4）：从 `snapshot.configuration` 提 image + env + 挂载摘要计数，
    /// 装进**纯 domain** `ContainerCloneTemplate`。**env 保持 `SecretString`、不 reveal**（D2）——
    /// 复用 `environment(from:)`，与 list 映射同一条脱敏路径。完整 configuration 仍留桥内（codex #1）。
    static func cloneTemplate(from snapshot: ContainerSnapshot) throws(MappingError) -> ContainerCloneTemplate {
        let reference = snapshot.configuration.image.reference
        guard let image = ImageRef(reference) else {
            throw .invalidImage(containerID: snapshot.id, raw: reference)
        }
        return ContainerCloneTemplate(
            image: image,
            environment: environment(from: snapshot.configuration.initProcess.environment),
            mountSummary: mountSummary(from: snapshot.configuration.mounts)
        )
    }

    /// 按上游 `Filesystem.FSType` 把挂载分流成 domain 的三桶计数。**穷尽 switch 无 default**——
    /// 上游加挂载类型 → 编译器强制在这里重新决定（R-FLAGS）。domain `MountSummary` 只有
    /// volume/bind/tmpfs 三桶（T2a 冻结）：`.block`（块设备/磁盘镜像）罕见且表单不支持新建，
    /// 并入 bind 计数——**宁可归错桶也要计入**，否则 total 静默漏计、UI 少报继承的挂载。
    static func mountSummary(from mounts: [Filesystem]) -> MountSummary {
        var volumeCount = 0
        var bindCount = 0
        var tmpfsCount = 0
        for mount in mounts {
            switch mount.type {
            case .volume: volumeCount += 1
            case .virtiofs, .block: bindCount += 1
            case .tmpfs: tmpfsCount += 1
            }
        }
        return MountSummary(volumeCount: volumeCount, bindCount: bindCount, tmpfsCount: tmpfsCount)
    }

    enum MappingError: Error, Equatable {
        case invalidID(raw: String)
        case invalidImage(containerID: String, raw: String)
    }
}
