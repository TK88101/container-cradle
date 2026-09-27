import Foundation
import Testing

@testable import ContainerCore

/// Day 22 T9：更新器的全部上屏文案（住 core 可测，四语）。
///
/// 两道防线：①穷尽——每个状态 / 失败原因 / 阶段都给得出文案（switch 穷尽由编译器守，这里守「非空」）；
/// ②不回显——ja / zh-Hans / zh-Hant 下每一条都不等于英文源串（= 翻译接上了，不是 key 回显）。
@Suite("RuntimeUpdatePresentation：穷尽、四语不回显、关键串逐字")
struct RuntimeUpdatePresentationTests {

    static let v141 = RuntimeVersion(major: 1, minor: 4, patch: 1)
    static let v150 = RuntimeVersion(major: 1, minor: 5, patch: 0)
    static let release = UpdatePolicyTests.release(v150)
    static let en = Locale(identifier: "en")
    static let zhHans = Locale(identifier: "zh-Hans")
    static let foreign = ["ja", "zh-Hans", "zh-Hant"].map(Locale.init(identifier:))

    static let failures: [UpdateFailure] = [
        .anotherJobRunning, .lockProbeFailed(73),
        .download(.network("x")), .download(.http(404)), .download(.sizeMismatch(expected: 1, actual: 2)), .download(.filesystem("x")),
        .verification(.digestMismatch), .verification(.signature(.signatureInvalid)), .verification(.signature(.signerUntrusted)),
        .verification(.unreadable), .verification(.ok),
        .rootVerification(.digestMismatch), .stopTimedOut(blockers: ["/usr/local/bin/container"]),
        .installFailed(details: ["installer-exit=1"]), .racedDuringInstall(blockers: ["/usr/local/bin/container"]),
        .versionMismatch(installed: .installed(v141)), .versionMismatch(installed: .notInstalled),
        .versionMismatch(installed: .unknown("x")), .startFailed(.timedOut), .unknown("x"), .interrupted,
        .installedButNotRestarted(v150), .snapshotUnavailable,
        // 不可信文本自带句末标点（R5 P2-9：夹具若只用常量，标点守卫就看不见这一类）。
        .unknown("osascript: execution error."), .installFailed(details: ["installer-exit=1."]),
    ]

    static let pendings: [PendingRestore] = [
        .runtimeStopped(because: .anotherJobRunning), .runtimeStopped(because: .lockProbeFailed(73)),
        .runtimeStopped(because: .startFailed(.timedOut)), .containersNotRestarted([ContainerID("buildkit")!]),
    ]

    static let states: [RuntimeUpdateStore.State] = [
        .checking, .upToDate(v141), .available(installed: v141, release: release), .skipped(installed: v141, release: release),
        .notInstalled, .checkFailed(.installedVersionUnknown("x")), .checkFailed(.rateLimited(until: Date(timeIntervalSince1970: 0))),
        .checkFailed(.release(.network("x"))), .checkFailed(.release(.http(500))), .checkFailed(.release(.feed(.malformed))),
        .checkFailed(.release(.feed(.noSignedPackage))), .checkFailed(.release(.feed(.notAStableRelease))),
        .checkFailed(.release(.feed(.unparsableVersion("x")))),
        .recovering, .succeeded(v150, unrestored: []), .succeeded(v150, unrestored: [ContainerID("buildkit")!]), .cancelled,
    ]
    + [UpdateStage.downloading, .verifying, .awaitingAuthorization, .stoppingRuntime, .installing, .startingRuntime, .restoringContainers, .abandoning]
        .map { RuntimeUpdateStore.State.updating(release, $0) }
    + failures.flatMap { failure in
        [RuntimeUpdateStore.State.failed(failure, pending: nil)]
            + pendings.map { RuntimeUpdateStore.State.failed(failure, pending: $0) }
    }

    @Test("idle 没有状态行；其余每个状态都有非空文案")
    func everyStateHasText() {
        #expect(RuntimeUpdatePresentation.statusText(for: .idle, locale: Self.en) == nil)
        for state in Self.states {
            let text = RuntimeUpdatePresentation.statusText(for: state, locale: Self.en)
            #expect(text?.isEmpty == false, "\(state)")
        }
    }

    @Test("非英语语言下每条文案都不等于英文（翻译已接上）", arguments: foreign)
    func noKeyEcho(locale: Locale) {
        for state in Self.states {
            let english = RuntimeUpdatePresentation.statusText(for: state, locale: Self.en)
            let translated = RuntimeUpdatePresentation.statusText(for: state, locale: locale)
            #expect(translated != english, "\(locale.identifier): \(state)")
        }
        #expect(RuntimeUpdatePresentation.authorizationPrompt(from: Self.v141, to: Self.v150, locale: locale)
            != RuntimeUpdatePresentation.authorizationPrompt(from: Self.v141, to: Self.v150, locale: Self.en))
        #expect(RuntimeUpdatePresentation.testedNote(installed: Self.v150, tested: Self.v141, locale: locale)
            != RuntimeUpdatePresentation.testedNote(installed: Self.v150, tested: Self.v141, locale: Self.en))
    }

    @Test("zh-Hans 逐字：可用 / 已是最新 / 运行时被留在停止状态")
    func zhHansGolden() {
        #expect(RuntimeUpdatePresentation.statusText(for: .available(installed: Self.v141, release: Self.release), locale: Self.zhHans)
            == "apple/container 1.5.0 可用（当前 1.4.1）")
        #expect(RuntimeUpdatePresentation.statusText(for: .upToDate(Self.v141), locale: Self.zhHans)
            == "apple/container 1.4.1 已是最新")
        #expect(RuntimeUpdatePresentation.statusText(for: .failed(.anotherJobRunning, pending: .runtimeStopped(because: .anotherJobRunning)), locale: Self.zhHans)
            == "另一个更新正在进行；运行时目前处于停止状态。")
    }

    @Test("zh-Hans 逐字：还欠着什么、为什么（R4 B/C/D）")
    func zhHansPendingGolden() {
        func text(_ failure: UpdateFailure, _ pending: PendingRestore?) -> String? {
            RuntimeUpdatePresentation.statusText(for: .failed(failure, pending: pending), locale: Self.zhHans)
        }
        #expect(text(.installFailed(details: ["x"]), .runtimeStopped(because: .anotherJobRunning))
            == "安装程序失败（x）；运行时目前处于停止状态：另一个更新正在进行。")
        #expect(text(.installedButNotRestarted(Self.v150), .runtimeStopped(because: .lockProbeFailed(73)))
            == "apple/container 1.5.0 已安装；运行时目前处于停止状态：无法确认是否有其他更新在进行（lockf 73）。")
        #expect(text(.interrupted, .containersNotRestarted([ContainerID("buildkit")!, ContainerID("web")!]))
            == "上一次更新被中断了；尚未重新启动：buildkit, web")
    }

    @Test("装上了只是没复原：通知标题不说「更新失败」，正文带原因并指向菜单（R4 B）")
    func installedButNotRestartedNotification() {
        let content = RuntimeUpdatePresentation.runtimeLeftStoppedNotification(
            failure: .installedButNotRestarted(Self.v150), because: .anotherJobRunning, locale: Self.en
        )
        #expect(content.title == "apple/container 1.5.0 was installed")
        #expect(content.body.contains("Another update is already in progress"))
        #expect(content.body.hasSuffix("Open the menu to start it."))
        let failed = RuntimeUpdatePresentation.runtimeLeftStoppedNotification(
            failure: .installFailed(details: []), because: .startFailed(.timedOut), locale: Self.en
        )
        #expect(failed.title == "apple/container update failed")
    }

    /// 失败文案一律不带句末标点、句间标点由模板负责（R4）：否则某个组合就会拼出「。。」「。；」「..」，或英文两句之间没有句号。
    @Test("四语 × 全部失败 × 全部欠账：拼出来的状态行与通知正文没有重复 / 缺失的句间标点", arguments: [en] + foreign)
    func noBrokenPunctuationWhenJoined(locale: Locale) {
        let broken = ["。。", "。；", "；。", "..", ".;", "。.", ".。"]
        var texts = Self.states.compactMap { RuntimeUpdatePresentation.statusText(for: $0, locale: locale) }
        for failure in Self.failures {
            let content = RuntimeUpdatePresentation.runtimeLeftStoppedNotification(failure: failure, because: .anotherJobRunning, locale: locale)
            texts.append(content.body)
        }
        for text in texts {
            #expect(!broken.contains { text.contains($0) }, "\(locale.identifier): \(text)")
            if locale.identifier == "en" {
                #expect(text.firstMatch(of: /[^.] (The runtime is stopped|Not restarted yet|Open the menu)/) == nil, "\(text)")
            }
        }
    }

    /// A4：检查失败的文案不能读起来像「已是最新」。
    @Test("检查失败的文案不含「up to date」")
    func failureNeverReadsAsUpToDate() {
        for state in Self.states {
            guard case .checkFailed = state else { continue }
            #expect(RuntimeUpdatePresentation.statusText(for: state, locale: Self.en)?.contains("up to date") == false)
        }
    }

    @Test("A9：已装 == 测过的版本不提示；不同才提示")
    func testedNote() {
        #expect(RuntimeUpdatePresentation.testedNote(installed: Self.v141, tested: Self.v141, locale: Self.en) == nil)
        #expect(RuntimeUpdatePresentation.testedNote(installed: nil, tested: Self.v141, locale: Self.en) == nil)
        #expect(RuntimeUpdatePresentation.testedNote(installed: Self.v150, tested: Self.v141, locale: Self.en)?.contains("1.4.1") == true)
    }

    @Test("可用通知：key 带版本（每个版本最多弹一次），正文含两个版本号")
    func availableNotification() {
        let content = RuntimeUpdatePresentation.availableNotification(release: Self.release, installed: Self.v141, locale: Self.en)
        #expect(content.key == "runtimeUpdate.available:1.5.0")
        #expect(content.title.contains("1.5.0"))
        #expect(content.body.contains("1.4.1"))
    }

    @Test("运行时被留在停止状态的通知：带失败原因")
    func leftStoppedNotification() {
        let content = RuntimeUpdatePresentation.runtimeLeftStoppedNotification(
            failure: .installFailed(details: []), because: .anotherJobRunning, locale: Self.en
        )
        #expect(content.key.hasPrefix("runtimeUpdate.leftStopped"))
        #expect(!content.body.isEmpty)
    }

    @Test("密码框提示含两个版本号")
    func authorizationPrompt() {
        let prompt = RuntimeUpdatePresentation.authorizationPrompt(from: Self.v141, to: Self.v150, locale: Self.en)
        #expect(prompt.contains("1.4.1"))
        #expect(prompt.contains("1.5.0"))
    }

    /// T13 发现 #1：macOS 27 忽略 `with prompt`（真机 + 对照实测），密码框里只剩系统文案。
    /// 弹框时唯一还说得出「装什么、会怎样」的是这条状态行——四语都必须带目标版本与重启后果。
    @Test("等待授权的状态行：四语都含目标版本与「运行时和容器会重启」", arguments: [
        ("en", "restart"), ("ja", "再起動"), ("zh-Hans", "重新启动"), ("zh-Hant", "重新啟動"),
    ])
    func awaitingAuthorizationNamesTargetAndRestart(language: String, restartWord: String) {
        let text = RuntimeUpdatePresentation.statusText(
            for: .updating(Self.release, .awaitingAuthorization), locale: Locale(identifier: language))
        #expect(text?.contains("1.5.0") == true, "\(language): \(text ?? "nil")")
        #expect(text?.contains(restartWord) == true, "\(language): \(text ?? "nil")")
    }

    @Test("已用时间：m:ss；时钟回拨按 0；超过一小时照常进位到分钟")
    func elapsed() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(RuntimeUpdatePresentation.elapsed(from: start, to: start.addingTimeInterval(206)) == "3:26")
        #expect(RuntimeUpdatePresentation.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0:00")
        #expect(RuntimeUpdatePresentation.elapsed(from: start, to: start.addingTimeInterval(6_000)) == "100:00")
    }
}
