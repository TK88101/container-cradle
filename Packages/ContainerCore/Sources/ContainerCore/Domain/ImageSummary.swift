/// 一个镜像的列表摘要。domain 侧的**唯一**镜像列表表示——上游的 `ImageDescription`
/// 到此为止（D1）。
///
/// 只有 reference + digest 两个 String：R11（image ls JSON 巨大）在 XPC 路由上
/// 结构性不存在（`ImageDescription` 不含 Dockerfile history），这里再收一层——
/// 「只解析需要的字段」结构性达成。单镜像体积刻意不带：要走 ContentStore 遍历
/// manifest（又一条 XPC），v1 无里程碑要求（DAY10-DEVPLAN §1）。
public struct ImageSummary: Sendable, Equatable, Identifiable {

    public var id: String { "\(reference.rawValue)@\(digest)" }

    public let reference: ImageRef
    public let digest: String

    public init(reference: ImageRef, digest: String) {
        self.reference = reference
        self.digest = digest
    }

    /// 12 位短 digest（展示用），剥掉 `sha256:` 这类算法前缀——与官方 CLI 的
    /// `Utility.trimDigest` 同口径（上游 `Utility.swift:51`）。
    public var shortDigest: String {
        let hex: String
        if let colon = digest.firstIndex(of: ":") {
            hex = String(digest[digest.index(after: colon)...])
        } else {
            hex = digest
        }
        return String(hex.prefix(12))
    }
}

/// `listImages()` 的返回：镜像列表 + **infra 过滤的权威性**。
///
/// `isInfraFilterAuthoritative == false` 表示 ACL 没能真实加载 config、过滤退化到了
/// stock 默认引用——此时展示可以降级，但**删除必须禁用**（D-C fail-closed：
/// 自定义 vminit 在退化过滤下会被暴露，删掉它 = 下次起容器失败）。
/// 这个旗标是 UI 禁删的**数据源**；ACL 的 `deleteImage` 内部还有第二道（★R3）。
public struct ImageListSnapshot: Sendable, Equatable {

    public let images: [ImageSummary]
    public let isInfraFilterAuthoritative: Bool

    public init(images: [ImageSummary], isInfraFilterAuthoritative: Bool) {
        self.images = images
        self.isInfraFilterAuthoritative = isInfraFilterAuthoritative
    }
}
