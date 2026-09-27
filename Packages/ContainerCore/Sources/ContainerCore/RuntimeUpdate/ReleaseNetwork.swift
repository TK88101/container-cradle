import Foundation

/// 一次「取 latest」的结果。**失败与限流各是各的，都不是「已是最新」**（Plan §4）。
public enum ReleaseCheckResult: Sendable, Equatable {
    case release(RuntimeRelease)
    case rateLimited(until: Date)
    case failed(ReleaseCheckFailure)
}

public enum ReleaseCheckFailure: Sendable, Equatable {
    /// 传输层失败（离线、DNS、TLS、超时）。
    case network(String)
    case http(Int)
    case feed(ReleaseFeedError)
}

public protocol ReleaseFeeding: Sendable {
    func latestRelease(now: Date) async -> ReleaseCheckResult
}

/// `GET /repos/apple/container/releases/latest`（Day 22 T6）。HTTP 层可注入，映射住这里、可测。
public struct GitHubReleaseFeed: ReleaseFeeding {

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let latestURL = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!

    /// 无缓存、无 cookie：每次都问最新，也不在本机留下任何东西。
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = GitHubReleaseFeed.urlSessionFetch) {
        self.fetch = fetch
    }

    public func latestRelease(now: Date) async -> ReleaseCheckResult {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ContainerCradle", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            return .failed(.network(error.localizedDescription))
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        if let until = GitHubReleaseDecoder.rateLimitedUntil(statusCode: response.statusCode, headers: headers, now: now) {
            return .rateLimited(until: until)
        }
        guard response.statusCode == 200 else { return .failed(.http(response.statusCode)) }

        do {
            return .release(try GitHubReleaseDecoder.decodeLatest(data))
        } catch {
            return .failed(.feed(error))
        }
    }
}

public enum DownloadFailure: Error, Sendable, Equatable {
    case network(String)
    case http(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case filesystem(String)
}

public protocol PackageDownloading: Sendable {
    /// 下载到一个新建的 0700 私有目录，返回 pkg 路径。调用方负责用完删掉整个目录。
    func download(_ release: RuntimeRelease) async throws(DownloadFailure) -> URL
}

/// 下载签名 pkg（Day 22 T6）。字节是否可信**不在这里判**——那是 `PackageVerifier`（digest + 签名）与 root 侧复验的事；
/// 这里只保证「落在只有本用户能进的目录里、尺寸与 API 声称的一致」。
public struct PackageDownloader: PackageDownloading {

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }()

    public init() {}

    static func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cof-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    public func download(_ release: RuntimeRelease) async throws(DownloadFailure) -> URL {
        let directory: URL
        do {
            directory = try Self.makeWorkDirectory()
        } catch {
            throw .filesystem(error.localizedDescription)
        }

        // 任何失败出口都删掉整个工作目录；只有成功返回时保留（调用方用完再删）。
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }

        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await Self.session.download(from: release.packageURL)
        } catch {
            throw .network(error.localizedDescription)
        }

        let destination = directory.appendingPathComponent(release.packageName)
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw DownloadFailure.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == release.packageSize else {
                throw DownloadFailure.sizeMismatch(expected: release.packageSize, actual: size)
            }
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw .filesystem(error.localizedDescription)
        }
        succeeded = true
        return destination
    }
}
