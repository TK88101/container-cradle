import ContainerCore

/// Day 28（Plan 2026-11-10-pin-1.7.1 §2.1 b′）：fresh create 的前置短路——**判断与编排，不碰上游类型**
/// （上游错误 → 本地性的那一步 `isPresent` 在 `UpstreamClient.swift`，边界白名单内）。
///
/// 1.7.1 client 的 `Utility.containerConfigFromFlags` 在镜像不在本地时先发 `.imagePlatforms`；
/// 这条路由 1.6.1 才有，1.6.0 server 的 `XPCServer` 对未知路由**不回复**（`if let handler` 无 else），
/// 上游 `ClientImage.platforms` 又不带 responseTimeout ⇒ 只能等到 300s create 超时。
/// 于是：运行中 server < 1.6.1 **且**镜像确定不在本地 ⇒ 不进装配，直接抛本 App 的拒绝。
///
/// 已接受的残余窗口（Plan b′-7）：预检判「在本地」到装配读本地 index 之间隔一个 `await`，
/// 用户恰在此间删掉同一镜像 ⇒ 旧运行时仍可能落回 300s 超时 = pin 前的现状，不更差。
/// 同一窗口里运行时若**换代**（升级 / 重启，simcodex R1 codex P2）：读到旧版本 + 新 server 的镜像状态 ⇒
/// 误拦一次（可操作的报错，重试即过）；读到新版本后又降回旧版 ⇒ 同样落回现状。不加 `RuntimeGeneration`
/// 令牌校验：装配在上游函数内部，令牌焊不进去，换不来更强的保证。
enum CreatePreflight {

    /// `.imagePlatforms` 首次出现的上游版本（1.6.0 无、1.6.1 有：`ImageServiceXPCRoutes.swift:24`）。
    static let imagePlatformsRouteSince = RuntimeVersion(major: 1, minor: 6, patch: 1)

    /// 运行中 server 版本需要先确认镜像在本地时，返回该版本（用于报错）；否则 nil。
    /// 版本不可解析（nil）⇒ 放行：不比 pin 前更差，也不因读不到版本挡住正常用户。
    static func versionRequiringLocalImage(serverVersion: RuntimeVersion?) -> RuntimeVersion? {
        guard let serverVersion, serverVersion < imagePlatformsRouteSince else { return nil }
        return serverVersion
    }

    /// 编排：需要时先问本地性，确定不在本地就抛 `.creation(.runtimeTooOldForRemoteImage)`、**不调 `assemble`**。
    /// `isImageLocal` 自身的错误原样抛出（不当成「不在本地」）。
    static func run<T>(
        serverVersion: RuntimeVersion?,
        isImageLocal: () async throws -> Bool,
        assemble: () async throws -> T
    ) async throws -> T {
        if let running = versionRequiringLocalImage(serverVersion: serverVersion), try await !isImageLocal() {
            throw RuntimeError.creation(.runtimeTooOldForRemoteImage(running: running))
        }
        return try await assemble()
    }
}
