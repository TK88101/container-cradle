import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T6：取 latest、下载、校验。HTTP 层注入，映射逐条断言；真网络只在 INTEGRATION=1 下跑。
@Suite("ReleaseNetwork / PackageVerifier：HTTP 映射、下载落点、digest 先于签名")
struct ReleaseNetworkTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func feed(status: Int, body: String = "", headers: [String: String] = [:]) -> GitHubReleaseFeed {
        GitHubReleaseFeed { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/apple/container/releases/latest")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    @Test("200 + 录制 JSON → release")
    func success() async {
        let result = await Self.feed(status: 200, body: GitHubReleaseDecoderTests.recorded141).latestRelease(now: Self.now)
        guard case .release(let release) = result else { Issue.record("\(result)"); return }
        #expect(release.version == RuntimeVersion(major: 1, minor: 4, patch: 1))
    }

    @Test("403 + 限流头 → rateLimited（带解除时间）")
    func rateLimited() async {
        let result = await Self.feed(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790003600"])
            .latestRelease(now: Self.now)
        #expect(result == .rateLimited(until: Date(timeIntervalSince1970: 1_790_003_600)))
    }

    @Test("其他非 200 → http 失败；解码失败 → feed 失败；传输错误 → network 失败")
    func failures() async {
        #expect(await Self.feed(status: 500).latestRelease(now: Self.now) == .failed(.http(500)))
        #expect(await Self.feed(status: 403).latestRelease(now: Self.now) == .failed(.http(403)))
        #expect(await Self.feed(status: 200, body: "nope").latestRelease(now: Self.now) == .failed(.feed(.malformed)))
        let offline = GitHubReleaseFeed { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed(.network) = await offline.latestRelease(now: Self.now) else {
            Issue.record("expected network failure"); return
        }
    }

    // MARK: - PackageVerifier

    /// SHA-256("abc")——FIPS 180-2 的标准测试向量。
    static let abcDigest = SHA256Digest(hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")!

    func fileWithABC() throws -> (TempDir, URL) {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.path("u.pkg"))
        try Data("abc".utf8).write(to: url)
        return (dir, url)
    }

    @Test("digest 对 + 签名 trusted → ok；pkgutil 参数逐字")
    func verifiesDigestThenSignature() async throws {
        let (dir, url) = try fileWithABC()
        _ = dir
        let runner = FakeProcessRunner()
        runner.respond(to: ["/usr/sbin/pkgutil", "--check-signature", url.path], stdout: PackageSignatureTests.signed141)
        #expect(await PackageVerifier(runner: runner).verify(url, expected: Self.abcDigest) == .ok)
    }

    /// digest 不对就不必再问签名（也就不给「签名看起来对」任何机会）。
    @Test("digest 不对 → digestMismatch，且根本不跑 pkgutil")
    func digestMismatchSkipsSignature() async throws {
        let (dir, url) = try fileWithABC()
        _ = dir
        let runner = FakeProcessRunner()
        let result = await PackageVerifier(runner: runner).verify(url, expected: SHA256Digest(hex: String(repeating: "0", count: 64))!)
        #expect(result == .digestMismatch)
        #expect(runner.calls.isEmpty)
    }

    @Test("签名不可信 → signature(verdict)；文件读不了 → unreadable")
    func signatureAndUnreadable() async throws {
        let (dir, url) = try fileWithABC()
        _ = dir
        let runner = FakeProcessRunner()
        runner.respond(to: ["/usr/sbin/pkgutil", "--check-signature", url.path], exitCode: 1, stdout: PackageSignatureTests.unsigned141)
        #expect(await PackageVerifier(runner: runner).verify(url, expected: Self.abcDigest) == .signature(.signatureInvalid))
        #expect(await PackageVerifier(runner: runner).verify(URL(fileURLWithPath: "/nonexistent/u.pkg"), expected: Self.abcDigest)
            == .unreadable)
    }

    // MARK: - 下载目录

    @Test("下载工作目录是 0700，且每次都是新的")
    func workDirectoryIsPrivate() throws {
        let a = try PackageDownloader.makeWorkDirectory()
        let b = try PackageDownloader.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a != b)
        let mode = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}

/// 真网络。`INTEGRATION=1`：取 latest 并解码。再加 `UPDATE_DOWNLOAD=1`：真下载当前 latest 的签名包并校验（约 118 MB）。
@Suite(
    "ReleaseNetwork 真网络（INTEGRATION=1）",
    .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1")
)
struct ReleaseNetworkIntegrationTests {

    @Test("真取 latest 并解码成签名包")
    func fetchesLatest() async throws {
        let result = await GitHubReleaseFeed().latestRelease(now: Date())
        guard case .release(let release) = result else { Issue.record("\(result)"); return }
        #expect(release.packageName.hasSuffix("-signed.pkg"))
    }

    @Test(
        "真下载 + 校验（UPDATE_DOWNLOAD=1）",
        .enabled(if: ProcessInfo.processInfo.environment["UPDATE_DOWNLOAD"] == "1")
    )
    func downloadsAndVerifies() async throws {
        guard case .release(let release) = await GitHubReleaseFeed().latestRelease(now: Date()) else {
            Issue.record("no release"); return
        }
        let file = try await PackageDownloader().download(release)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(await PackageVerifier().verify(file, expected: release.packageSHA256) == .ok)
    }
}
