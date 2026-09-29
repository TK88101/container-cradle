import Foundation
import Testing

@testable import ContainerCore

/// Day 23 T6：运行时自动启动的上屏文案（住 core 可测，四语）。
/// 同 `RuntimeUpdatePresentationTests` 两道防线：①穷尽非空；②ja / zh-Hans / zh-Hant 不回显英文源串。
@Suite("RuntimeAutoStartPresentation：穷尽、四语不回显、通知 key 稳定")
struct RuntimeAutoStartPresentationTests {

    static let en = Locale(identifier: "en")
    static let foreign = ["ja", "zh-Hans", "zh-Hant"].map(Locale.init(identifier:))

    static let failures: [RuntimeAutoStartFailure] = [
        .commandFailed(exitCode: 1), .timedOut, .notInstalled, .notReady, .blockedByUpdater,
    ]

    static let deferrals: [RuntimeAutoStartDeferral] = [
        .updaterBusy, .updaterOwesRuntimeStart, .privilegedJobRunning, .lockProbeFailed,
    ]

    static let states: [RuntimeAutoStarter.State] =
        [.starting]
        + deferrals.map { .deferred($0) }
        + failures.map { .failed($0) }

    @Test("idle 不占行；其余每个状态都有非空文案")
    func everyStateHasText() {
        #expect(RuntimeAutoStartPresentation.statusText(for: .idle, locale: Self.en) == nil)
        for state in Self.states {
            #expect(RuntimeAutoStartPresentation.statusText(for: state, locale: Self.en)?.isEmpty == false, "\(state)")
        }
    }

    @Test("外语下每个状态行都不回显英文源串", arguments: foreign)
    func statusTranslated(locale: Locale) {
        for state in Self.states {
            let english = RuntimeAutoStartPresentation.statusText(for: state, locale: Self.en)
            let translated = RuntimeAutoStartPresentation.statusText(for: state, locale: locale)
            #expect(translated != english, "\(locale.identifier) \(state)")
        }
    }

    @Test("外语下每个失败通知都不回显英文源串", arguments: foreign)
    func notificationTranslated(locale: Locale) {
        for failure in Self.failures {
            let english = RuntimeAutoStartPresentation.failureNotification(failure, locale: Self.en)
            let translated = RuntimeAutoStartPresentation.failureNotification(failure, locale: locale)
            #expect(translated.title != english.title, "\(locale.identifier) \(failure)")
            #expect(translated.body != english.body, "\(locale.identifier) \(failure)")
        }
    }

    @Test("通知：key 稳定、正文带原因与「按按钮重试」的指引")
    func notificationContent() {
        let content = RuntimeAutoStartPresentation.failureNotification(.timedOut, locale: Self.en)
        #expect(content.key == "runtimeAutoStart.failed")
        #expect(content.title == "The container runtime did not start")
        #expect(content.body.contains("timed out"))
        #expect(content.body.contains("Start Runtime"))
    }

    @Test("退出码原样透传（技术细节保持可搜索）")
    func exitCodeVerbatim() {
        let text = RuntimeAutoStartPresentation.statusText(for: .failed(.commandFailed(exitCode: 73)), locale: Self.en)
        #expect(text?.contains("73") == true)
        #expect(text?.contains("container system start") == true)
    }

    // MARK: - 横幅按钮（simplify R1 altitude：判断从 view 挪进 core）

    static func banner(
        _ error: RuntimeError = .runtimeUnavailable,
        state: RuntimeAutoStarter.State = .idle,
        primary: Bool = true,
        manualRestore: Bool = false,
        terminating: Bool = false
    ) -> RuntimeAutoStartPresentation.StartBanner? {
        RuntimeAutoStartPresentation.startBanner(
            for: error, state: state, isPrimaryInstance: primary,
            hasManualRestore: manualRestore, isTerminating: terminating, locale: en
        )
    }

    @Test("运行时没在跑 → 有按钮、可点；idle 不带状态行")
    func bannerShownWhenRuntimeDown() {
        #expect(Self.banner() == .init(status: nil, isStartEnabled: true))
    }

    @Test("别的错误 / 副实例 / 更新器已有复原按钮 → 整块不画")
    func bannerHidden() {
        #expect(Self.banner(.containerNotFound(ContainerID("x")!)) == nil)
        #expect(Self.banner(.operationFailed(reason: "x")) == nil)
        #expect(Self.banner(primary: false) == nil)
        #expect(Self.banner(manualRestore: true) == nil)
    }

    @Test("在途 / 退出开始之后 → 按钮禁用；失败 / 延后 → 可点并带状态行")
    func bannerEnablement() {
        #expect(Self.banner(state: .starting)?.isStartEnabled == false)
        #expect(Self.banner(terminating: true)?.isStartEnabled == false)
        #expect(Self.banner(state: .failed(.timedOut))?.isStartEnabled == true)
        #expect(Self.banner(state: .deferred(.updaterBusy))?.isStartEnabled == true)
        #expect(Self.banner(state: .failed(.timedOut))?.status?.contains("timed out") == true)
    }

    @Test("失败原因不带句末标点（模板负责标点，避免「。。」）")
    func reasonsHaveNoTrailingPunctuation() {
        for locale in [Self.en] + Self.foreign {
            for failure in Self.failures {
                let reason = RuntimeAutoStartPresentation.failureReason(failure, locale: locale)
                #expect(!reason.isEmpty)
                #expect(!(reason.last.map { ".。".contains($0) } ?? false), "\(locale.identifier) \(failure): \(reason)")
            }
        }
    }
}
