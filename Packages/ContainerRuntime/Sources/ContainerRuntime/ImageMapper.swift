import ContainerCore
import ContainerResource

/// `ImageDescription` → `ImageSummary`。只碰 reference / digest 两个 String——
/// R11 的「只解析需要的字段」在这里结构性达成（`digest` 是 `ImageDescription` 上的
/// String 计算属性，`Descriptor` 类型根本不出现在本文件）。
///
/// ## 失败关闭（Day 6 ④ 同款）
///
/// reference 映射不出来（空串）→ 抛错让整个 `listImages()` 失败，不静默丢镜像：
/// 静默消失的镜像 = 用户以为它没了、其实还占着盘，而一切看起来完全正常。
enum ImageMapper {

    struct UnmappableImage: Error, CustomStringConvertible {
        let reference: String
        var description: String { "无法映射镜像 reference：'\(reference)'" }
    }

    static func map(_ description: ImageDescription) throws -> ImageSummary {
        guard let reference = ImageRef(description.reference) else {
            throw UnmappableImage(reference: description.reference)
        }
        return ImageSummary(reference: reference, digest: description.digest)
    }
}
