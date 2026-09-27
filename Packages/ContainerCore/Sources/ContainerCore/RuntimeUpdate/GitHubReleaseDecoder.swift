import Foundation

/// `GET /repos/apple/container/releases/latest` 的响应 → `RuntimeRelease`（Day 22 T1）。纯函数，住 core 可测。
///
/// ## 失败关闭
///
/// 任何一处对不上都宁可说「没有可用更新」——这里选出来的 URL 和 digest，最后会交给一段以 root 运行的
/// 脚本去安装。于是规则都是「逐字相等」而不是「看起来像」：
/// - 资产名只认上游 `update-container.sh` 认的两个签名包名（主名、带版本号的备名），**永不选 unsigned**；
/// - `browser_download_url` 必须**逐字等于** `https://github.com/apple/container/releases/download/<tag>/<name>`
///   （防 host 后缀伪装、防别的仓库、防 query 串）；
/// - `digest` 必须是 `sha256:<64 hex>`——缺了就没有东西能把 root 装的字节钉死在「用户侧验过的那份」上；
/// - 发布页 URL 由 tag 自己拼，不信响应里的 `html_url`。
///
/// ## 三种「没有」不折叠（Plan §4）
///
/// `malformed`（查询结果读不懂）/ `notAStableRelease` / `unparsableVersion` / `noSignedPackage`
/// 各是各的——UI 据此说「检查失败」还是「这个版本没有可安装的签名包」，**绝不说成「已是最新」**。
public enum GitHubReleaseDecoder {

    /// 上游签名包的两个名字（与 `/usr/local/bin/update-container.sh` 的 `SIGNED_PRIMARY_PKG` / `SIGNED_FALLBACK_PKG` 一致）。
    static func signedPackageNames(tag: String) -> [String] {
        ["container-installer-signed.pkg", "container-\(tag)-installer-signed.pkg"]
    }

    static let downloadPrefix = "https://github.com/apple/container/releases/download/"
    static let releasePagePrefix = "https://github.com/apple/container/releases/tag/"

    public static func decodeLatest(_ data: Data) throws(ReleaseFeedError) -> RuntimeRelease {
        let dto: ReleaseDTO
        do {
            dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)
        } catch {
            throw .malformed
        }

        guard !dto.draft, !dto.prerelease else { throw .notAStableRelease }
        guard let version = RuntimeVersion(parsing: dto.tagName) else {
            throw .unparsableVersion(dto.tagName)
        }

        for name in signedPackageNames(tag: dto.tagName) {
            for asset in dto.assets where asset.name == name {
                if let release = validated(asset, tag: dto.tagName, version: version) {
                    return release
                }
            }
        }
        throw .noSignedPackage
    }

    /// 一个名字对得上的候选：URL 逐字、digest、size 全过才算数；任何一项不过就跳过它（不挡住后面的好候选）。
    private static func validated(_ asset: AssetDTO, tag: String, version: RuntimeVersion) -> RuntimeRelease? {
        let expectedURL = downloadPrefix + tag + "/" + asset.name
        guard asset.browserDownloadURL == expectedURL,
              let packageURL = URL(string: expectedURL),
              let digestText = asset.digest,
              digestText.hasPrefix("sha256:"),
              let digest = SHA256Digest(hex: String(digestText.dropFirst("sha256:".count))),
              let size = asset.size, size > 0,
              let pageURL = URL(string: releasePagePrefix + tag)
        else { return nil }

        return RuntimeRelease(
            version: version,
            packageName: asset.name,
            packageURL: packageURL,
            packageSHA256: digest,
            packageSize: size,
            releasePageURL: pageURL
        )
    }

    /// 这次响应是不是**限流**，是的话到什么时候解除；`nil` = 不是限流（或解除时间已过）。
    ///
    /// - `Retry-After`（秒）优先；其次 `X-RateLimit-Remaining: 0` 配 `X-RateLimit-Reset`（epoch 秒）。头名大小写无关。
    /// - **403 没有限流信号就不当限流**：403 也可能是别的拒绝，把它当限流会错误地静默一整段时间。
    /// - **429 本身就是限流信号**：没有合法的解除时间时至少等 60 秒（GitHub 文档对次级限流的建议）。
    /// - **最多 1 小时**（安全评审 L7）：响应头由网络对端说了算，一个离谱的值不能让检查停摆几天；GitHub 主限流窗口本身就是 1 小时。
    public static func rateLimitedUntil(statusCode: Int, headers: [String: String], now: Date) -> Date? {
        guard statusCode == 403 || statusCode == 429 else { return nil }

        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let latest = now.addingTimeInterval(maximumRateLimitWait)

        if let seconds = lowered["retry-after"].flatMap({ Int($0) }), seconds > 0 {
            return min(now.addingTimeInterval(TimeInterval(seconds)), latest)
        }
        if lowered["x-ratelimit-remaining"] == "0",
           let reset = lowered["x-ratelimit-reset"].flatMap({ Int($0) }) {
            let date = Date(timeIntervalSince1970: TimeInterval(reset))
            if date > now { return min(date, latest) }
        }
        return statusCode == 429 ? now.addingTimeInterval(60) : nil
    }

    static let maximumRateLimitWait: TimeInterval = 3600

    // MARK: - DTO（只解判定需要的字段；多余字段忽略）

    private struct ReleaseDTO: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [AssetDTO]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease, assets
        }
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64?
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// `releases/latest` 解码失败的原因。与「网络失败」「限流」（在 `ReleaseNetwork` 那一层）一起，
/// 构成「检查失败」的全部来源——它们都不是「已是最新」。
public enum ReleaseFeedError: Error, Equatable, Sendable {
    /// 不是 JSON，或缺必需字段。
    case malformed
    /// draft 或 prerelease。
    case notAStableRelease
    /// tag 不是正式版号。
    case unparsableVersion(String)
    /// 没有一个通过全部校验的签名包。
    case noSignedPackage
}
