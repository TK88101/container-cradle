import ContainerCore
import ContainerResource

/// `VolumeConfiguration` → `Volume`。**没有失败路径**：上游字段全非可选
/// （`sizeInBytes` 本来就是可选 → 映射成可选的稀疏上限），不需要 fail-closed 的抛错面。
///
/// `usedBytes` 不来自 `VolumeConfiguration`——那是 `.volumeDiskUsage` 路由的事
/// （enrichment，见 `VolumeUsageCollector`），mapper 只负责把两者拼起来。
///
/// 上游改字段时，只有本文件（和它的白名单同伴）编译不过——这就是它单独成文件的意义。
enum VolumeMapper {

    static func map(_ configuration: VolumeConfiguration, usedBytes: UInt64?) -> Volume {
        Volume(
            name: configuration.name,
            creationDate: configuration.creationDate,
            source: configuration.source,
            sizeMaxBytes: configuration.sizeInBytes,
            usedBytes: usedBytes
        )
    }
}
