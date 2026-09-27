import Testing

@testable import ContainerCore

/// Day 22 T3：`pkgutil --check-signature` 的判定契约。**user 侧与 root 侧是同一套规则**（Plan §5.3），
/// 这里守的是 Swift 那一份；root 脚本那一份由 T5 的 smoke 用同样的真实 pkg 守。
///
/// 正例 fixture 是 2026-09-25 对真 `container-1.4.1-installer-signed.pkg` 录的原样输出（`LC_ALL=C`）；
/// unsigned 是对真 `container-installer-unsigned.pkg` 录的；其余标注「合成」的是在正例上做单点改动。
@Suite("PackageSignature：状态有效 + 已公证 + 第 1 条证书是 UPBK2H6LZM 的 Installer 证书")
struct PackageSignatureTests {

    static let signed141 = """
    Package "c141.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-09-09 01:41:27 +0000
       Certificate Chain:
        1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)
           Expires: 2030-06-04 16:44:29 +0000
           SHA256 Fingerprint:
               45 19 B4 3D 00 F5 5E C6 31 38 D4 03 DE 1F 3C 54 23 90 EA E3 D8 2E
               59 C1 84 38 46 FB DF E1 4F 5B
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
           SHA256 Fingerprint:
               F1 6C D3 C5 4C 7F 83 CE A4 BF 1A 3E 6A 08 19 C8 AA A8 E4 A1 52 8F
               D1 44 71 5F 35 06 43 D2 DF 3A
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
           SHA256 Fingerprint:
               B0 B1 73 0E CB C7 FF 45 05 14 2C 49 F1 29 5E 6E DA 6B CA ED 7E 2C
               68 C5 BE 91 B5 A1 10 01 F0 24

    """

    static let unsigned141 = """
    Package "c141-unsigned.pkg":
       Status: no signature

    """

    @Test("真实签名包 → trusted")
    func trustsRecordedSignedPackage() {
        #expect(PackageSignature.evaluate(pkgutilOutput: Self.signed141, exitCode: 0) == .trusted)
    }

    @Test("真实 unsigned 包（退出码 1）→ signatureInvalid")
    func rejectsRecordedUnsignedPackage() {
        #expect(PackageSignature.evaluate(pkgutilOutput: Self.unsigned141, exitCode: 1) == .signatureInvalid)
    }

    /// 退出码是第一道：输出看起来再像，pkgutil 自己说失败就是失败。
    @Test("输出对但退出码非 0 → signatureInvalid")
    func nonZeroExitIsInvalid() {
        #expect(PackageSignature.evaluate(pkgutilOutput: Self.signed141, exitCode: 1) == .signatureInvalid)
    }

    @Test("空输出 → signatureInvalid")
    func emptyOutputIsInvalid() {
        #expect(PackageSignature.evaluate(pkgutilOutput: "", exitCode: 0) == .signatureInvalid)
    }

    @Test("（合成）Status 行不是「Apple 签发、用于分发」→ signatureInvalid")
    func wrongStatusIsInvalid() {
        let output = Self.signed141.replacingOccurrences(
            of: "Status: signed by a developer certificate issued by Apple for distribution",
            with: "Status: signed by a certificate trusted by Mac OS X"
        )
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signatureInvalid)
    }

    @Test("（合成）缺公证行 → signerUntrusted")
    func missingNotarizationIsUntrusted() {
        let output = Self.signed141.replacingOccurrences(
            of: "   Notarization: trusted by the Apple notary service\n", with: ""
        )
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signerUntrusted)
    }

    @Test("（合成）第 1 条证书的 team 不是 UPBK2H6LZM → signerUntrusted")
    func otherTeamIsUntrusted() {
        let output = Self.signed141.replacingOccurrences(of: "(UPBK2H6LZM)", with: "(ABCDE12345)")
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signerUntrusted)
    }

    /// 只认链上**第 1 条**（叶子证书）：team ID 出现在别处不算。
    @Test("（合成）team 只出现在第 2 条证书 → signerUntrusted")
    func teamOnlyInSecondCertificateIsUntrusted() {
        let output = Self.signed141
            .replacingOccurrences(of: "1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)",
                                  with: "1. Developer ID Installer: Someone Else (ABCDE12345)")
            .replacingOccurrences(of: "2. Developer ID Certification Authority",
                                  with: "2. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)")
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signerUntrusted)
    }

    @Test("（合成）第 1 条是 Application 证书而非 Installer → signerUntrusted")
    func applicationCertificateIsUntrusted() {
        let output = Self.signed141.replacingOccurrences(
            of: "1. Developer ID Installer:", with: "1. Developer ID Application:"
        )
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signerUntrusted)
    }

    /// team ID 必须是**结尾**那个括号，不是名字里某处出现的子串。
    @Test("（合成）team ID 只出现在证书名中间 → signerUntrusted")
    func teamIDMustBeTrailing() {
        let output = Self.signed141.replacingOccurrences(
            of: "1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)",
            with: "1. Developer ID Installer: Fake (UPBK2H6LZM) Corp (ABCDE12345)"
        )
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signerUntrusted)
    }

    /// Status 行必须是**整行**相等（去掉行首空白后），不是包含。
    @Test("（合成）Status 行带多余后缀 → signatureInvalid")
    func statusMustMatchWholeLine() {
        let output = Self.signed141.replacingOccurrences(
            of: "issued by Apple for distribution", with: "issued by Apple for distribution (revoked)"
        )
        #expect(PackageSignature.evaluate(pkgutilOutput: output, exitCode: 0) == .signatureInvalid)
    }
}
