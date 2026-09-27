import Foundation
import Testing

@testable import ContainerCore

/// R-U15（R5 A；codex 补评：有条件同意暂缓，要求补这条测试）：冻结白名单过期——用户在升级途中（冻结之后）才把 X 设为受管，
/// 复原时更新器按冻结的名单把 X 当未受管去起，supervisor 按新白名单也起 X。两个启动者之间没有容器级的串行令牌（长期方案：单一协调者分配启动所有权）。
///
/// 这里钉住「短暂竞争、最终一致」在代码里的两半：
/// ① 更新器按**最终在跑列表**报告——自己那次 start 输了（对方先起来了）不会被报成「没拉回」；
/// ② supervisor 那一轮输了只是一次 transient 失败（走退避），下一轮 start 在「已在跑」上幂等短路成功。
/// 竞争用可阻塞的 fake 强制重叠：两个启动者都越过「已在跑」的短路才放行，赢家起成功，输家在赢家起完之后拿到失败。
///
/// 不在这里的（残余，写进 §9 R-U15）：输家的失败若**早于**赢家起完返回，更新器那次 `ls` 看不到 X 在跑，会把它列为「尚未重新启动」——
/// 一次性快照，之后按钮会短路；上游对并发 bootstrap 实际给什么错、supervisor 据此归哪一档，未实测（TBD）。
@Suite("R-U15：更新器与 supervisor 同时起同一个容器（冻结白名单过期）——不论谁赢，最终一致")
struct RuntimeUpdateDoubleStarterTests {

    enum Starter: String, Sendable, CaseIterable {
        case updater
        case supervisor
    }

    /// 两个启动者共用的容器世界。
    actor World {
        /// 第一个启动者最多等第二个这么久。等不到 = 没重叠（例如将来 R-U15 的长期修法落地、只剩一个启动者）——
        /// 放行并记 `overlapForced = false`，让测试**变红**而不是把测试进程冻住（R6 评审）。
        static let overlapWait: Duration = .seconds(5)

        let winner: Starter
        private(set) var running: Set<ContainerID> = []
        private(set) var starts: [Starter] = []
        /// 两个启动者真的在「起」这一步重叠了（屏障等到了第二个）。
        private(set) var overlapForced = false
        private var bootstrapping = 0
        private var atBootstrap: CheckedContinuation<Void, Never>?
        private var winnerDone = false
        private var waitingForWinner: [CheckedContinuation<Void, Never>] = []

        init(winner: Starter) { self.winner = winner }

        func start(_ id: ContainerID, by starter: Starter) async -> Bool {
            starts.append(starter)
            if running.contains(id) { return true }              // 上游 CLI / client 共有的幂等短路
            bootstrapping += 1
            if bootstrapping == 1 {
                Task { try? await Task.sleep(for: Self.overlapWait); self.releaseBarrier() }
                await withCheckedContinuation { atBootstrap = $0 }         // 等另一个启动者也越过短路（有界）
            } else {
                overlapForced = true
                releaseBarrier()
            }
            guard overlapForced else {                           // 没等到对手：无竞争地起成功
                running.insert(id)
                return true
            }
            if starter == winner {
                running.insert(id)
                winnerDone = true
                waitingForWinner.forEach { $0.resume() }
                waitingForWinner = []
                return true
            }
            if !winnerDone { await withCheckedContinuation { waitingForWinner.append($0) } }
            return false
        }

        private func releaseBarrier() {
            atBootstrap?.resume()
            atBootstrap = nil
        }
    }

    /// 更新器一侧（CLI）。只有 `ls` / `container start` 会被 `restoreContainers` 用到。
    struct WorldCommands: RuntimeCommanding {
        let world: World
        func installedVersion() async -> InstalledRuntime { .notInstalled }
        func stopRuntime() async -> CommandOutcome { .failed(exitCode: 1, detail: "unused") }
        func startRuntime() async -> CommandOutcome { .failed(exitCode: 1, detail: "unused") }
        func isRuntimeRunning() async -> Bool { true }
        func runningContainerIDs() async -> Result<[ContainerID], CommandFailure> { .success(Array(await world.running)) }
        func startContainer(_ id: ContainerID) async -> CommandOutcome {
            await world.start(id, by: .updater) ? .succeeded : .failed(exitCode: 1, detail: "bootstrap in progress")
        }
        func privilegedJobState() async -> PrivilegedJobState { .idle }
    }

    /// supervisor 一侧（XPC client）。
    struct WorldClient: ContainerRuntimeClient, VolumeImageUnimplementedTestDouble {
        let world: World
        func list() throws(RuntimeError) -> [Container] { [] }
        func start(id: ContainerID) async throws(RuntimeError) {
            guard await world.start(id, by: .supervisor) else { throw .operationFailed(reason: "bootstrap in progress") }
        }
        func stop(id: ContainerID) throws(RuntimeError) {}
        func followLogs(id: ContainerID) throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func stats(id: ContainerID) throws(RuntimeError) -> ContainerStatsSample { ContainerStatsSample() }
    }

    /// 白名单的**当前**值：X 已受管（冻结的那份里还没有它）。
    struct CurrentWhitelist: WhitelistProvider {
        let ids: [ContainerID]
        func entries() async -> [WhitelistEntry] { ids.map { WhitelistEntry(id: $0) } }
    }

    static let x = ContainerID("buildkit")!

    @MainActor
    @Test("冻结之后才受管的容器被两边同时起：容器在跑、更新器不误报、supervisor 输了只是一轮 transient、下一轮幂等成功", arguments: Starter.allCases)
    func bothStartersConverge(winner: Starter) async {
        let world = World(winner: winner)
        let store = RuntimeUpdateStore(
            environment: RuntimeUpdateEnvironment(
                commands: WorldCommands(world: world),
                clock: ImmediateClock(),
                log: SpyRuntimeUpdateLog(),
                managedContainerIDs: { [] },
                requestManagedReconcile: {},
                authorizationPrompt: { _, _ in "" }
            ),
            preferences: InMemoryUpdatePreferences()
        )
        let engine = WhitelistReconcileEngine(client: WorldClient(world: world), whitelist: CurrentWhitelist(ids: [Self.x]))
        let generation = RuntimeGeneration(pid: 42, startTime: 1)
        // 冻结的受管名单是空的：更新器把 X 当未受管去拉。
        let intent = UpdateIntent(
            nonce: UUID(), target: RuntimeUpdateStoreTests.v150, from: RuntimeUpdateStoreTests.v141,
            runtimeWasRunning: true, stopIssued: true, runningContainerIDs: [Self.x], managedContainerIDs: []
        )

        async let supervisorRound = engine.reconcile(generation: generation)
        let unrestored = await store.restoreContainers(intent)
        let firstRound = await supervisorRound

        #expect(await world.overlapForced)                                            // 两边真的在「起」这一步重叠了
        #expect(await world.starts.sorted { $0.rawValue < $1.rawValue } == [.supervisor, .updater])
        #expect(await world.running == [Self.x])
        #expect(unrestored.isEmpty)                                                   // ①
        #expect(firstRound == (winner == .supervisor ? .success : .failure(.transient)))
        #expect(await engine.reconcile(generation: generation) == .success)           // ②
    }
}
