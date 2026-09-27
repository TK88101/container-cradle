import Testing

@testable import ContainerCore

/// Day 22 T1：运行时更新器的领域值——版本号与 SHA-256。
///
/// 两者都是「构造即校验」：非法值构造不出来（坑清单「边界值会绕过硬约束」）。
/// 版本号只认正式版：prerelease / build 后缀一律拒——`releases/latest` 本就不返回预发布，
/// 若哪天真出现了，宁可「没有可用更新」也不要把一个 `1.5.0-rc1` 当成比 `1.4.1` 新去装。
@Suite("RuntimeUpdateDomain：版本号与摘要构造即校验")
struct RuntimeUpdateDomainTests {

    // MARK: - RuntimeVersion

    @Test("正式版号原样解析；前导 v 与无 v 是同一个版本", arguments: ["1.4.1", "v1.4.1"])
    func parsesPlainVersion(raw: String) throws {
        let version = try #require(RuntimeVersion(parsing: raw))
        #expect(version == RuntimeVersion(major: 1, minor: 4, patch: 1))
        #expect(version.description == "1.4.1")
    }

    @Test(
        "非正式版号构造不出来",
        arguments: [
            "", " ", "1", "1.4", "1.4.1.0", "1.4.1-rc1", "1.4.1+build5", "V1.4.1", "vv1.4.1",
            " 1.4.1", "1.4.1 ", "1..1", "01.4.1", "1.04.1", "a.b.c", "-1.4.1", "1.4.-1", "１.4.1",
            "99999999999999999999.0.0",
        ]
    )
    func rejectsNonReleaseVersion(raw: String) {
        #expect(RuntimeVersion(parsing: raw) == nil)
    }

    /// 零本身合法（`1.0.0`），只拒「多余的前导零」——那是非规范写法，两种写法比较相等会让「跳过的版本」对不上。
    @Test("单个 0 合法")
    func acceptsZeroComponents() {
        #expect(RuntimeVersion(parsing: "0.0.0") == RuntimeVersion(major: 0, minor: 0, patch: 0))
        #expect(RuntimeVersion(parsing: "1.0.10") == RuntimeVersion(major: 1, minor: 0, patch: 10))
    }

    /// 字符串比较会把 `1.10.0` 排在 `1.9.9` 前面——这正是要用三元组的原因。
    @Test("按数值逐段比较，不按字符串")
    func comparesNumerically() throws {
        let v1_9_9 = try #require(RuntimeVersion(parsing: "1.9.9"))
        let v1_10_0 = try #require(RuntimeVersion(parsing: "1.10.0"))
        let v2_0_0 = try #require(RuntimeVersion(parsing: "2.0.0"))
        #expect(v1_9_9 < v1_10_0)
        #expect(v1_10_0 < v2_0_0)
        #expect(!(v1_10_0 < v1_10_0))
    }

    // MARK: - SHA256Digest

    @Test("64 位 hex 构造成功，统一成小写")
    func acceptsHexDigest() throws {
        let upper = "C0D2716AFEFBB194C93FAE662E9CAE7CC186BCBCF746816608EC673DD648A6A4"
        let digest = try #require(SHA256Digest(hex: upper))
        #expect(digest.hex == upper.lowercased())
        #expect(SHA256Digest(hex: upper.lowercased()) == digest)
    }

    @Test(
        "长度不对或含非 hex 字符构造不出来",
        arguments: [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "g", count: 64),
            "sha256:" + String(repeating: "a", count: 64),
            " " + String(repeating: "a", count: 63),
        ]
    )
    func rejectsBadDigest(raw: String) {
        #expect(SHA256Digest(hex: raw) == nil)
    }
}
