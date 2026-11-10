import Testing
import Synchronization

@testable import ContainerCore

/// Day 29（Plan G5 / R2-3）：更新前在跑的 plugin 容器，更新器既不复原、也不列为欠着的。
@MainActor
@Suite("RuntimeUpdateStore：plugin 容器不复原")
struct RuntimeUpdatePluginExclusionTests {

    @Test("更新前在跑 [a, buildkit]、buildkit 归插件 → 收尾只 start a，buildkit 不进意图记录")
    func pluginNotRestored() async throws {
        let h = try RuntimeUpdateStoreTests.Harness(
            script: .init(
                installedAfterInstall: .installed(RuntimeUpdateStoreTests.v150),
                runtimeRunning: true,
                running: ["a", "buildkit"]
            ),
            plugins: ["buildkit"]
        )
        let prefs = h.prefs
        let recorded = Mutex<[ContainerID]?>(nil)
        h.commands.onStop.withLock { $0 = { @Sendable in
            let ids = await MainActor.run { prefs.intent?.runningContainerIDs }
            recorded.withLock { $0 = ids }
        } }

        await h.run { $0.checkForUpdates() }

        #expect(h.store.state == .succeeded(RuntimeUpdateStoreTests.v150, unrestored: []))
        #expect(recorded.withLock { $0 } == [ContainerID("a")!])
        #expect(h.log.count("start:a") == 1)
        #expect(h.log.count("start:buildkit") == 0)
    }
}
