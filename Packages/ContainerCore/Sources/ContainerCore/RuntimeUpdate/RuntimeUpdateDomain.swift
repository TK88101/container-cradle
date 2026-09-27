import Foundation

/// apple/container 运行时的**正式版**版本号（Day 22）。
///
/// 构造即校验，只认 `X.Y.Z`（可带一个小写前导 `v`，与上游 tag 的两种习惯都兼容）：
/// - **拒绝 prerelease / build 后缀**：`releases/latest` 本不返回预发布；万一返回了，
///   宁可「没有可用更新」，也不把 `1.5.0-rc1` 当成比 `1.4.1` 新去装。
/// - **拒绝多余的前导零**（`01.4.1`）：非规范写法与规范写法比较相等，会让「跳过的版本」对不上号。
/// - **只认 ASCII 数字**：`Character.isNumber` 会放过全角 `１`。
///
/// 比较按三元组逐段取数值——字符串比较会把 `1.10.0` 排在 `1.9.9` 前面。
public struct RuntimeVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let body = raw.hasPrefix("v") ? raw.dropFirst() : Substring(raw)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let number = Self.component(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// 一段非负整数：非空、全是 ASCII 数字、无多余前导零、不溢出。
    private static func component(_ text: Substring) -> Int? {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              text == "0" || !text.hasPrefix("0")
        else { return nil }
        return Int(text)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: RuntimeVersion, rhs: RuntimeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// SHA-256 摘要（64 位 hex，统一成小写）。构造即校验——root 脚本拿它做逐字比较，
/// 大小写不一致会让一个正确的包被判成「digest 不符」。
public struct SHA256Digest: Sendable, Hashable, Codable {

    public let hex: String

    public init?(hex raw: String) {
        let hexDigits = "0123456789abcdefABCDEF".unicodeScalars
        guard raw.unicodeScalars.count == 64,
              raw.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
        else { return nil }
        self.hex = raw.lowercased()
    }
}

/// 一个**可安装**的最新正式版：版本号 + 它的**签名** pkg。
///
/// 只能由 `GitHubReleaseDecoder` 在全部校验通过后构造出来——「没有签名包的 release」根本不是一个 `RuntimeRelease`
/// （概念表：它**不是**一个可用更新）。
public struct RuntimeRelease: Sendable, Equatable, Codable {

    public let version: RuntimeVersion
    public let packageName: String
    public let packageURL: URL
    public let packageSHA256: SHA256Digest
    public let packageSize: Int64
    public let releasePageURL: URL

    public init(
        version: RuntimeVersion,
        packageName: String,
        packageURL: URL,
        packageSHA256: SHA256Digest,
        packageSize: Int64,
        releasePageURL: URL
    ) {
        self.version = version
        self.packageName = packageName
        self.packageURL = packageURL
        self.packageSHA256 = packageSHA256
        self.packageSize = packageSize
        self.releasePageURL = releasePageURL
    }
}
