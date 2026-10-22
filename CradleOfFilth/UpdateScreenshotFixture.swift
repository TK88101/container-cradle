#if DEBUG
import ContainerCore
import ContainerRuntime
import Foundation

/// 仅 DEBUG：菜单截图用的更新器夹具（codex R5 补评 D，D 辩论 3 轮收敛）。启动参数 `-COFUpdateFixtureContainerDebt <id,id>`。
///
/// 摆出「新版本装上了、只欠这些容器」那一屏（按钮「Start Remaining Containers」+ 状态行「尚未重新启动：…」），给四语截图用——
/// 走真流程要先制造一次解除，截图时做不到。
///
/// **只隔离更新器**：CLI / 网络 / 下载 / 校验 / 提权安装 / defaults / reconcile 请求全是惰性替身，也不占真租约（见 `AppModel.init`）——
/// 误点任何按钮都不起进程、不发请求、不写偏好。
/// supervisor 照 DEBUG 包的常态运行（冷启动只读探测、不 reconcile；截图要的是真实排版），不归夹具管。
enum UpdateScreenshotFixture {

    @MainActor
    static func containerDebtStore(_ rawIDs: String) -> RuntimeUpdateStore {
        let ids = rawIDs.split(separator: ",").compactMap { ContainerID(String($0)) }
        let from = UpstreamPin.version
        let installed = RuntimeVersion(major: from.major, minor: from.minor + 1, patch: 0)
        let store = inertStore()
        store.presentContainerDebtFixture(ids, installed: installed, from: from)
        return store
    }

    /// Day 24 A/B 验收（Plan 2026-10-21 A/B-fx）：启动参数 `-COFUpdateFixtureRecheckRateLimited <秒>`。
    /// 摆出「有可用版本 + 这次撞了限流没能重新确认」，限流在启动后 `<秒>` 解除——菜单不关，到点看状态行改口。
    /// 误点「Update Now」落到惰性下载器的失败，不发请求、不弹密码框。
    @MainActor
    static func recheckRateLimitedStore(_ rawSeconds: String) -> RuntimeUpdateStore {
        let seconds = TimeInterval(rawSeconds) ?? 60
        let installed = UpstreamPin.version
        let target = RuntimeVersion(major: installed.major, minor: installed.minor + 1, patch: 0)
        let release = RuntimeRelease(
            version: target,
            packageName: "container-\(target)-installer-signed.pkg",
            packageURL: URL(string: "https://invalid.example/screenshot-fixture.pkg")!,
            packageSHA256: SHA256Digest(hex: String(repeating: "0", count: 64))!,
            packageSize: 0,
            releasePageURL: URL(string: "https://github.com/apple/container/releases")!
        )
        let store = inertStore()
        store.presentRecheckFailureFixture(
            installed: installed, release: release, failure: .rateLimited(until: Date().addingTimeInterval(seconds))
        )
        return store
    }

    @MainActor
    private static func inertStore() -> RuntimeUpdateStore {
        let environment = RuntimeUpdateEnvironment(
            feed: OfflineFeed(),
            downloader: InertDownloader(),
            verifier: InertVerifier(),
            installer: InertInstaller(),
            commands: InertCommands(),
            managedContainerIDs: { [] },
            requestManagedReconcile: {},
            authorizationPrompt: { _, _ in "" }
        )
        return RuntimeUpdateStore(environment: environment, preferences: MemoryPreferences(), isPrimaryInstance: true)
    }

    /// 误点「检查更新」只落到 checkFailed：不发 GitHub 请求。
    private struct OfflineFeed: ReleaseFeeding {
        func latestRelease(now: Date) async -> ReleaseCheckResult { .failed(.network("screenshot fixture")) }
    }

    /// 下载 / 校验 / 提权安装：结构上到不了（`install()` 要 available / skipped，而检查只会落到 checkFailed）——仍一律惰性，纵深防御（R6 评审）。
    private struct InertDownloader: PackageDownloading {
        func download(_ release: RuntimeRelease) async throws(DownloadFailure) -> URL { throw .network("screenshot fixture") }
    }

    private struct InertVerifier: PackageVerifying {
        func verify(_ file: URL, expected: SHA256Digest) async -> PackageVerification { .unreadable }
    }

    private struct InertInstaller: PrivilegedInstalling {
        func run(
            package: URL, digest: SHA256Digest, version: RuntimeVersion, nonce: UUID, prompt: String,
            onReady: @escaping @Sendable () async -> Void
        ) async -> PrivilegedJobOutcome { .cancelled }
        func readStateFile(nonce: UUID) -> PrivilegedJobStateFile? { nil }
    }

    /// 每个方法都是确定性的失败 / 空结果，不起任何进程（codex D 第 3 轮：误点「Start Remaining Containers」也不许碰真 CLI）。
    private struct InertCommands: RuntimeCommanding {
        func installedVersion() async -> InstalledRuntime { .unknown("screenshot fixture") }
        func stopRuntime() async -> CommandOutcome { .failed(exitCode: 1, detail: "screenshot fixture") }
        func startRuntime() async -> CommandOutcome { .failed(exitCode: 1, detail: "screenshot fixture") }
        func isRuntimeRunning() async -> Bool { true }
        func runningContainerIDs() async -> Result<[ContainerID], CommandFailure> { .failure(CommandFailure("screenshot fixture")) }
        func startContainer(_ id: ContainerID) async -> CommandOutcome { .failed(exitCode: 1, detail: "screenshot fixture") }
        func privilegedJobState() async -> PrivilegedJobState { .probeFailed(0) }
    }

    /// 内存偏好：不碰 defaults；自动检查关着（调度器不会把夹具状态覆盖成「检查中」）。
    @MainActor
    private final class MemoryPreferences: UpdatePreferences {
        var skippedVersion: RuntimeVersion?
        var lastSuccessfulCheck: Date?
        var rateLimitedUntil: Date?
        var intent: UpdateIntent?
        var isAutomaticCheckEnabled = false
    }
}
#endif
