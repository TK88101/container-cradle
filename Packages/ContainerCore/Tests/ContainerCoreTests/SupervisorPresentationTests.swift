import Foundation
import Testing

@testable import ContainerCore

/// 这些字符串不是排版，是**判断**——所以它们要被测。
///
/// 「启动失败」和「等待挂载源就绪（外置盘还没挂上？）」的区别，是用户去翻日志
/// 还是去插硬盘。而 R13 的核心场景（Mac 重启后外置盘还没挂上）**恰恰**是后者。
@Suite("SupervisorPresentation")
struct SupervisorPresentationTests {

    private let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)

    /// ★ 熔断在菜单栏上**必须刺眼**。熔断意味着 supervisor 从此不干活了，
    /// 而它不干活的样子和一切正常长得一模一样——图标若不变，用户永远不会知道。
    @Test("熔断的图标与正常态不同")
    func circuitOpenLooksDifferent() {
        let normal = SupervisorPresentation.symbol(for: .runtimeUp(generation: g1, baseline: false))
        let broken = SupervisorPresentation.symbol(
            for: .circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 0))
        )

        #expect(normal != broken)
        #expect(SupervisorPresentation.symbol(for: .runtimeDown) != normal)

        // 只有熔断该报警。别的状态（包括「运行时不在」）都是常态，不该天天喊狼来了——
        // 喊多了，真熔断那次就没人看了。
        #expect(SupervisorPresentation.isAlarming(.circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 0))))
        #expect(!SupervisorPresentation.isAlarming(.runtimeDown))
        #expect(!SupervisorPresentation.isAlarming(.runtimeUp(generation: g1, baseline: false)))
        #expect(!SupervisorPresentation.isAlarming(.reconciling(generation: g1, failures: nil)))
    }

    /// ★ 三种失败必须说三种话——它们要用户做的事完全不同。
    @Test(
        "失败原因逐档不同",
        arguments: [FailureKind.environmentNotReady, .transient, .permanent]
    )
    func failureReasonsAreDistinct(kind: FailureKind) {
        let text = SupervisorPresentation.detail(
            for: .reconcileFailed(
                generation: g1,
                kind: kind,
                attempt: 2,
                retryAt: Date(timeIntervalSince1970: 100)
            )
        )

        let others: [FailureKind] = [.environmentNotReady, .transient, .permanent]
            .filter { $0 != kind }

        let otherTexts = others.map { other in
            SupervisorPresentation.detail(
                for: .reconcileFailed(
                    generation: g1,
                    kind: other,
                    attempt: 2,
                    retryAt: Date(timeIntervalSince1970: 100)
                )
            )
        }

        #expect(text != nil)
        #expect(!otherTexts.contains(text))
    }

    /// R13 那一档要**指向硬盘**，不能指向日志。
    @Test("environmentNotReady 说的是挂载源，不是笼统的启动失败")
    func environmentNotReadyPointsAtTheMount() {
        let text = SupervisorPresentation.detail(
            for: .reconcileFailed(
                generation: g1,
                kind: .environmentNotReady,
                attempt: 1,
                retryAt: Date(timeIntervalSince1970: 100)
            )
        )

        #expect(text?.contains("挂载") == true)
    }

    /// 成功不该在界面上留一行「上次成功了」的噪音。
    @Test("成功没有 detail")
    func successHasNoDetail() {
        #expect(SupervisorPresentation.detail(for: .reconcileSucceeded(generation: g1)) == nil)
        #expect(SupervisorPresentation.detail(for: nil) == nil)
    }

    /// ★ A3：`generation(for:)` 从 `AppModel` 搬过来的穷尽 switch——逐分支验证，
    /// 而不只是「不崩」。`.unknown`/`.runtimeDown` 没有代，其余四态都带着代号。
    @Test("unknown 与 runtimeDown 没有代")
    func noGenerationBeforeRuntimeIsUp() {
        #expect(SupervisorPresentation.generation(for: .unknown) == nil)
        #expect(SupervisorPresentation.generation(for: .runtimeDown) == nil)
    }

    @Test("runtimeUp/reconciling/cooldown/circuitOpen 都带着各自的代号")
    func everyOtherStateCarriesItsGeneration() {
        let g2 = RuntimeGeneration(pid: 200, startTime: 2_000)

        #expect(SupervisorPresentation.generation(for: .runtimeUp(generation: g1, baseline: true)) == g1)
        #expect(SupervisorPresentation.generation(for: .reconciling(generation: g2, failures: nil)) == g2)
        #expect(
            SupervisorPresentation.generation(
                for: .cooldown(
                    generation: g1,
                    until: Date(timeIntervalSince1970: 10),
                    failures: FailureStreak(attempts: 1, breakerFailures: [])
                )
            ) == g1
        )
        #expect(
            SupervisorPresentation.generation(
                for: .circuitOpen(generation: g2, since: Date(timeIntervalSince1970: 0))
            ) == g2
        )
    }

    /// 每个状态都得有话可说——将来加 case 时，穷尽 switch 会逼人写一句。
    @Test("所有状态都有非空的状态行与图标")
    func everyStateHasHeadline() {
        let states: [SupervisorState] = [
            .unknown,
            .runtimeDown,
            .runtimeUp(generation: g1, baseline: true),
            .runtimeUp(generation: g1, baseline: false),
            .reconciling(generation: g1, failures: nil),
            .cooldown(
                generation: g1,
                until: Date(timeIntervalSince1970: 10),
                failures: FailureStreak(attempts: 2, breakerFailures: [])
            ),
            .circuitOpen(generation: g1, since: Date(timeIntervalSince1970: 0)),
        ]

        for state in states {
            #expect(!SupervisorPresentation.headline(for: state).isEmpty)
            #expect(!SupervisorPresentation.symbol(for: state).isEmpty)
        }
    }
}
