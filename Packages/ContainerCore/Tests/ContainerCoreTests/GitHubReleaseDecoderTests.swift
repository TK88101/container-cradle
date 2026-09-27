import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T1：`releases/latest` → `RuntimeRelease`。**失败关闭**：任何一处对不上，宁可「没有可用更新」。
///
/// fixture 是 2026-09-25 从真 API（`GET /repos/apple/container/releases/latest`）录下的 1.4.1 响应，
/// 只裁掉了与判定无关的字段，其余逐字保留。
@Suite("GitHubReleaseDecoder：只认签名包、URL 逐字、digest 必备")
struct GitHubReleaseDecoderTests {

    static let signedName = "container-1.4.1-installer-signed.pkg"
    static let signedURL = "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg"
    static let signedDigest = "sha256:c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4"

    static let recorded141 = """
    {
      "html_url": "https://github.com/apple/container/releases/tag/1.4.1",
      "tag_name": "1.4.1",
      "name": "1.4.1",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-09-09T01:28:43Z",
      "assets": [
        {
          "name": "container-1.4.1-installer-signed.pkg",
          "content_type": "application/octet-stream",
          "state": "uploaded",
          "size": 117773865,
          "digest": "sha256:c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4",
          "browser_download_url": "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg"
        },
        {
          "name": "container-dSYM.zip",
          "content_type": "application/zip",
          "state": "uploaded",
          "size": 154754382,
          "digest": "sha256:2c4d69bca8ff2e532923fe36c84bb41c3d119fa27074e237c103f3757a2fe131",
          "browser_download_url": "https://github.com/apple/container/releases/download/1.4.1/container-dSYM.zip"
        },
        {
          "name": "container-installer-unsigned.pkg",
          "content_type": "application/octet-stream",
          "state": "uploaded",
          "size": 115284732,
          "digest": "sha256:7f2784bdd506c95347f8130382004a600800ec8f306162ad9211d83378ec3a68",
          "browser_download_url": "https://github.com/apple/container/releases/download/1.4.1/container-installer-unsigned.pkg"
        }
      ]
    }
    """

    /// 构造一份只含判定字段的 release JSON。
    static func release(
        tag: String = "1.4.1",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]
    ) -> Data {
        let object: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func asset(
        name: String = signedName,
        url: String = signedURL,
        digest: String? = signedDigest,
        size: Int = 117_773_865
    ) -> [String: Any] {
        var asset: [String: Any] = ["name": name, "browser_download_url": url, "size": size]
        if let digest { asset["digest"] = digest }
        return asset
    }

    // MARK: - 正例

    @Test("录制的 1.4.1 响应解出签名包")
    func decodesRecordedRelease() throws {
        let release = try GitHubReleaseDecoder.decodeLatest(Data(Self.recorded141.utf8))

        #expect(release.version == RuntimeVersion(major: 1, minor: 4, patch: 1))
        #expect(release.packageName == Self.signedName)
        #expect(release.packageURL.absoluteString == Self.signedURL)
        #expect(release.packageSHA256.hex == "c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4")
        #expect(release.packageSize == 117_773_865)
        // 发布页 URL 由 tag 自己拼，不信响应里的 html_url。
        #expect(release.releasePageURL.absoluteString == "https://github.com/apple/container/releases/tag/1.4.1")
    }

    /// 上游 `update-container.sh` 认两个名字：主名 `container-installer-signed.pkg`、备名带版本号。
    @Test("不带版本号的主名也认")
    func acceptsUnversionedSignedName() throws {
        let name = "container-installer-signed.pkg"
        let data = Self.release(assets: [
            Self.asset(name: name, url: "https://github.com/apple/container/releases/download/1.4.1/\(name)"),
        ])
        #expect(try GitHubReleaseDecoder.decodeLatest(data).packageName == name)
    }

    @Test("tag 带 v 前缀：URL 按原 tag 逐字比对，版本号去 v")
    func acceptsVPrefixedTag() throws {
        let name = "container-v1.5.0-installer-signed.pkg"
        let data = Self.release(tag: "v1.5.0", assets: [
            Self.asset(name: name, url: "https://github.com/apple/container/releases/download/v1.5.0/\(name)"),
        ])
        let release = try GitHubReleaseDecoder.decodeLatest(data)
        #expect(release.version == RuntimeVersion(major: 1, minor: 5, patch: 0))
        #expect(release.releasePageURL.absoluteString == "https://github.com/apple/container/releases/tag/v1.5.0")
    }

    // MARK: - 反例：不是一个可用的正式版

    @Test("draft / prerelease 一律拒")
    func rejectsDraftAndPrerelease() {
        #expect(throws: ReleaseFeedError.notAStableRelease) {
            try GitHubReleaseDecoder.decodeLatest(Self.release(draft: true, assets: [Self.asset()]))
        }
        #expect(throws: ReleaseFeedError.notAStableRelease) {
            try GitHubReleaseDecoder.decodeLatest(Self.release(prerelease: true, assets: [Self.asset()]))
        }
    }

    @Test("tag 不是正式版号 → 拒", arguments: ["1.5.0-rc1", "latest", ""])
    func rejectsUnparsableTag(tag: String) {
        #expect(throws: ReleaseFeedError.unparsableVersion(tag)) {
            try GitHubReleaseDecoder.decodeLatest(Self.release(tag: tag, assets: [Self.asset()]))
        }
    }

    @Test("不是 JSON / 缺必需字段 → malformed", arguments: ["", "not json", "[]", #"{"tag_name":"1.4.1"}"#])
    func rejectsMalformed(raw: String) {
        #expect(throws: ReleaseFeedError.malformed) {
            try GitHubReleaseDecoder.decodeLatest(Data(raw.utf8))
        }
    }

    // MARK: - 反例：没有可用的签名包（与「查询失败」是两件事，不许折叠）

    @Test("只有 unsigned 包 → noSignedPackage（永不选 unsigned）")
    func neverPicksUnsigned() {
        let name = "container-installer-unsigned.pkg"
        let data = Self.release(assets: [
            Self.asset(name: name, url: "https://github.com/apple/container/releases/download/1.4.1/\(name)"),
        ])
        #expect(throws: ReleaseFeedError.noSignedPackage) {
            try GitHubReleaseDecoder.decodeLatest(data)
        }
    }

    @Test(
        "URL 任何一段对不上 → noSignedPackage",
        arguments: [
            "http://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg",
            "https://github.com.evil.example/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg",
            "https://github.com/evil/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg",
            "https://github.com/apple/container/releases/download/1.4.0/container-1.4.1-installer-signed.pkg",
            "https://github.com/apple/container/releases/download/1.4.1/other.pkg",
            "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg?x=1",
            "https://objects.githubusercontent.com/whatever/container-1.4.1-installer-signed.pkg",
        ]
    )
    func rejectsMismatchedURL(url: String) {
        let data = Self.release(assets: [Self.asset(url: url)])
        #expect(throws: ReleaseFeedError.noSignedPackage) {
            try GitHubReleaseDecoder.decodeLatest(data)
        }
    }

    @Test("资产名是别的版本号 → noSignedPackage")
    func rejectsNameForOtherVersion() {
        let name = "container-1.4.0-installer-signed.pkg"
        let data = Self.release(assets: [
            Self.asset(name: name, url: "https://github.com/apple/container/releases/download/1.4.1/\(name)"),
        ])
        #expect(throws: ReleaseFeedError.noSignedPackage) {
            try GitHubReleaseDecoder.decodeLatest(data)
        }
    }

    @Test(
        "digest 缺失 / 不是 sha256 / 长度不对 → noSignedPackage",
        arguments: [
            nil,
            "c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4",
            "sha512:c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4",
            "sha256:c0d2716a",
            "sha256:",
        ] as [String?]
    )
    func rejectsBadDigest(digest: String?) {
        let data = Self.release(assets: [Self.asset(digest: digest)])
        #expect(throws: ReleaseFeedError.noSignedPackage) {
            try GitHubReleaseDecoder.decodeLatest(data)
        }
    }

    @Test("非正的 size → noSignedPackage", arguments: [0, -1])
    func rejectsNonPositiveSize(size: Int) {
        let data = Self.release(assets: [Self.asset(size: size)])
        #expect(throws: ReleaseFeedError.noSignedPackage) {
            try GitHubReleaseDecoder.decodeLatest(data)
        }
    }

    @Test("一个坏的签名包候选不挡住另一个好的")
    func skipsBadCandidate() throws {
        let good = "container-installer-signed.pkg"
        let data = Self.release(assets: [
            Self.asset(digest: nil),
            Self.asset(name: good, url: "https://github.com/apple/container/releases/download/1.4.1/\(good)"),
        ])
        #expect(try GitHubReleaseDecoder.decodeLatest(data).packageName == good)
    }

    // MARK: - 限流

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("429 / 403 带 Retry-After（秒）→ now + 秒数", arguments: [403, 429])
    func retryAfterSeconds(status: Int) {
        let date = GitHubReleaseDecoder.rateLimitedUntil(
            statusCode: status, headers: ["Retry-After": "120"], now: Self.now
        )
        #expect(date == Self.now.addingTimeInterval(120))
    }

    @Test("带 X-RateLimit-Reset（epoch 秒）且剩余 0 → 该时刻；头名大小写无关")
    func rateLimitReset() {
        let date = GitHubReleaseDecoder.rateLimitedUntil(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0", "X-RATELIMIT-RESET": "1790003600"],
            now: Self.now
        )
        #expect(date == Date(timeIntervalSince1970: 1_790_003_600))
    }

    /// 安全评审 L7：响应头是网络对端说了算的——一个离谱的 `Retry-After` / `X-RateLimit-Reset`
    /// 不能让自动检查（和手动检查的「HH:MM 后再试」）停摆几天。GitHub 的主限流窗口本身就是 1 小时。
    @Test("限流解除时间夹到 now + 1h", arguments: [
        ["Retry-After": "999999"],
        ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "4102444800"],
    ] as [[String: String]])
    func rateLimitIsCappedAtOneHour(headers: [String: String]) {
        #expect(GitHubReleaseDecoder.rateLimitedUntil(statusCode: 403, headers: headers, now: Self.now)
            == Self.now.addingTimeInterval(3600))
    }

    /// 403 也可能是别的原因（被拒、仓库不可见）——没有限流信号就不当限流处理，否则会错误地静默一整段时间。
    @Test("403 没有任何限流信号 → 不是限流")
    func forbiddenWithoutRateLimitSignal() {
        #expect(GitHubReleaseDecoder.rateLimitedUntil(statusCode: 403, headers: [:], now: Self.now) == nil)
        #expect(GitHubReleaseDecoder.rateLimitedUntil(
            statusCode: 403, headers: ["X-RateLimit-Remaining": "12", "X-RateLimit-Reset": "1790003600"], now: Self.now
        ) == nil)
    }

    @Test("200 / 404 不是限流；解除时间已过或头值非法 → 不是限流")
    func notRateLimited() {
        #expect(GitHubReleaseDecoder.rateLimitedUntil(statusCode: 200, headers: ["Retry-After": "60"], now: Self.now) == nil)
        #expect(GitHubReleaseDecoder.rateLimitedUntil(statusCode: 404, headers: [:], now: Self.now) == nil)
        #expect(GitHubReleaseDecoder.rateLimitedUntil(
            statusCode: 403, headers: ["Retry-After": "soon"], now: Self.now
        ) == nil)
        #expect(GitHubReleaseDecoder.rateLimitedUntil(
            statusCode: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000"], now: Self.now
        ) == nil)
    }

    /// 429 本身就是限流信号：没有给出（合法的）解除时间时，按 GitHub 文档的建议至少等一分钟。
    @Test("429 无合法时间头 → now + 60s", arguments: [[:], ["Retry-After": "soon"]] as [[String: String]])
    func tooManyRequestsWithoutHeaders(headers: [String: String]) {
        #expect(GitHubReleaseDecoder.rateLimitedUntil(statusCode: 429, headers: headers, now: Self.now)
            == Self.now.addingTimeInterval(60))
    }
}
