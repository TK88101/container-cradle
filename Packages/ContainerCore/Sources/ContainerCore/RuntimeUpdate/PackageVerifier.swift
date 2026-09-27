import CryptoKit
import Foundation

public enum PackageVerification: Sendable, Equatable {
    case ok
    case digestMismatch
    case signature(PackageSignature.Verdict)
    case unreadable
}

public protocol PackageVerifying: Sendable {
    func verify(_ file: URL, expected: SHA256Digest) async -> PackageVerification
}

/// user 侧校验（Day 22 T6）：**先 digest、再签名**。digest 不对就不必再问签名——也就不给「签名看起来对」任何机会。
/// 这一步失败，升级在弹密码框之前就结束，运行时从未被碰（Plan §5.3）。root 侧会对私有副本按同一契约再验一次。
public struct PackageVerifier: PackageVerifying {

    static let pkgutilPath = "/usr/sbin/pkgutil"
    static let signatureTimeout: Duration = .seconds(60)
    static let chunkSize = 1 << 20

    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func verify(_ file: URL, expected: SHA256Digest) async -> PackageVerification {
        guard let actual = await Self.sha256(of: file) else { return .unreadable }
        guard actual == expected else { return .digestMismatch }

        // ProcessRunner 已为子进程设 LC_ALL=C（PackageSignature 按字面解析输出）。
        guard let result = try? await runner.run(
            Self.pkgutilPath, arguments: ["--check-signature", file.path], timeout: Self.signatureTimeout
        ) else { return .signature(.signatureInvalid) }

        let verdict = PackageSignature.evaluate(pkgutilOutput: result.stdout, exitCode: result.exitCode)
        return verdict == .trusted ? .ok : .signature(verdict)
    }

    /// 流式计算（118 MB 不整块读进内存），放到后台执行器上跑，不占调用方（store 在 MainActor 上）。
    static func sha256(of file: URL) async -> SHA256Digest? {
        await Task.detached(priority: .utility) { () -> SHA256Digest? in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                // 读错是 throw（→ 不可读）；读到 EOF 是返回 nil 或空 Data（→ 读完了）。两者不许混。
                let chunk: Data?
                do { chunk = try handle.read(upToCount: chunkSize) } catch { return nil }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return SHA256Digest(hex: hex)
        }.value
    }
}
