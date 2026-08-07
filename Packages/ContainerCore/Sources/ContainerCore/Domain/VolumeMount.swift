/// fresh 创建时的一条挂载——**只能是 named volume**（codex #16）。
///
/// 刻意只有 `{volumeName, containerPath, readOnly}` 三个字段：
/// 没有宿主源路径（bind）、没有 tmpfs 标记。于是「fresh 表单能建 bind/tmpfs」在**类型上**
/// 就表达不出来——那是 non-goal（需宿主路径选择器，超范围）。clone 复制时随 configuration
/// 带过全类型挂载，但那条路径不经此类型。
///
/// 校验不落在此类型：`ContainerCreationSpec` 是 fresh 创建的校验单点。容器路径**唯一性**是真·跨条目
/// 校验（只有 spec 看得到整张列表）；容器路径**绝对性**虽是单条目属性，也一并归 spec 集中校验——
/// `VolumeMount` 刻意保持纯三元组、不自证（区别于 fresh/clone 共用、需自证合法的 `ContainerName`）。
public struct VolumeMount: Sendable, Equatable {

    public let volumeName: String
    public let containerPath: String
    public let readOnly: Bool

    public init(volumeName: String, containerPath: String, readOnly: Bool) {
        self.volumeName = volumeName
        self.containerPath = containerPath
        self.readOnly = readOnly
    }
}
