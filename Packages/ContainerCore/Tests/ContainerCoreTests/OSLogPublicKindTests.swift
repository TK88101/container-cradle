import Testing

@testable import ContainerCore

/// 日志里 `RuntimeError` 的公开 case 名是日志查询的接口：改名会让既有查询静默失效。
/// Day 26 把 create 专属的三个 case 收成 `.creation(...)` 时，名字刻意保持 Day 24–25 的原样（Plan 2026-10-23 §2.1）。
@Suite("OSLogSupervisorLog.publicKind：case 名字符串不变")
struct OSLogPublicKindTests {

    @Test(
        "每个 case 的公开名",
        arguments: [
            (RuntimeError.runtimeUnavailable, "runtimeUnavailable"),
            (.containerNotFound(ContainerID("web")!), "containerNotFound"),
            (.mountSourceUnavailable(path: "/Volumes/data"), "mountSourceUnavailable"),
            (.operationFailed(reason: "boom"), "operationFailed"),
            (.creation(.outcomeUnknown(reason: "t")), "outcomeUnknown"),
            (.creation(.inProgress(name: "web")), "creationInProgress"),
            (.creation(.limitReached(limit: 8)), "creationLimitReached"),
        ]
    )
    func publicKind(error: RuntimeError, expected: String) {
        #expect(OSLogSupervisorLog.publicKind(error) == expected)
    }
}
