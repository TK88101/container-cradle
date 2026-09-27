import Foundation

/// `pkgutil --check-signature` 的判定契约（Day 22 T3）。**失败关闭**。
///
/// ## 与 root 侧是同一套规则
///
/// 下载后 user 侧先判一次（失败就不弹密码框、不碰运行时）；root 在自己的私有副本上再判一次
/// （防 TOCTOU，Plan §5.3）。两处必须是**同一个契约**——root 侧弱一格，第二道防线就形同虚设
/// （codex 第 1 轮 C5）。所以规则写成最朴素的三条整行比较，root 脚本里用 `grep -Fx` 逐字复刻：
///
/// 1. `pkgutil` 退出码 0，且去掉首尾空白后有一行**整行等于** `Status: signed by a developer certificate issued by Apple for distribution`
///    （否则 `.signatureInvalid`）；
/// 2. 有一行整行等于 `Notarization: trusted by the Apple notary service`（否则 `.signerUntrusted`）；
/// 3. 证书链**第 1 条**（叶子）以 `1. Developer ID Installer: ` 开头、以 ` (UPBK2H6LZM)` 结尾（否则 `.signerUntrusted`）——
///    team ID 必须是结尾那个括号；出现在第 2 条、或名字中间，都不算。
///
/// 不加 `spctl`：它依赖本机 Gatekeeper 策略，关掉时放行一切、「仅 App Store」时拒 Apple 自己的包（codex C5，已撤回）。
/// 调用方负责 `LC_ALL=C`。
public enum PackageSignature {

    /// apple/container 签名包的签名者 team（2026-09-25 实测：`Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)`）。
    public static let teamID = "UPBK2H6LZM"

    static let statusLine = "Status: signed by a developer certificate issued by Apple for distribution"
    static let notarizationLine = "Notarization: trusted by the Apple notary service"
    static let leafPrefix = "1. Developer ID Installer: "

    public enum Verdict: Sendable, Equatable {
        case trusted
        /// 没签名 / 签名无效 / pkgutil 自己报失败。
        case signatureInvalid
        /// 签名有效，但不是我们信任的那个签名者（或未公证）。
        case signerUntrusted
    }

    public static func evaluate(pkgutilOutput: String, exitCode: Int32) -> Verdict {
        let lines = pkgutilOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard exitCode == 0, lines.contains(statusLine) else { return .signatureInvalid }
        guard lines.contains(notarizationLine) else { return .signerUntrusted }

        guard let leaf = lines.first(where: { $0.hasPrefix("1. ") }),
              leaf.hasPrefix(leafPrefix),
              leaf.hasSuffix(" (\(teamID))")
        else { return .signerUntrusted }

        return .trusted
    }
}
