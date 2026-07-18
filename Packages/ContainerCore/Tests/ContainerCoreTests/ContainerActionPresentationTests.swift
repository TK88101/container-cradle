import Foundation
import Testing

@testable import ContainerCore

@Suite("ContainerActionPresentation：动作失败文案（restart 半失败必须可区分）")
struct ContainerActionPresentationTests {

    private let en = Locale(identifier: "en")
    private let zhHans = Locale(identifier: "zh-Hans")

    @Test("restart 半失败：文案必须以「已停止，但启动失败」开头——用户要知道容器现在是停的")
    func restartHalfFailureSaysStopped() {
        let message = ContainerActionPresentation.message(
            for: .restartStartFailed(.operationFailed(reason: "image gone")),
            locale: en
        )
        #expect(message.hasPrefix("Stopped, but start failed"))
        #expect(message.contains("image gone"))
    }

    @Test("restart 停止阶段失败：文案必须说明容器仍在运行——和半失败是相反的处境")
    func restartStopFailureSaysStillRunning() {
        let message = ContainerActionPresentation.message(
            for: .restartStopFailed(.runtimeUnavailable),
            locale: en
        )
        #expect(message.contains("the container is still running"))
        #expect(message.contains("The container runtime is not running"))
    }

    @Test("普通 stop / start 失败：形态词 + 底层原因都在")
    func plainFailuresCarryDetail() {
        let stop = ContainerActionPresentation.message(
            for: .stopFailed(.containerNotFound(ContainerID("web")!)),
            locale: en
        )
        #expect(stop.hasPrefix("Stop failed"))
        #expect(stop.contains("web"))

        let start = ContainerActionPresentation.message(
            for: .startFailed(.mountSourceUnavailable(path: "/Volumes/data")),
            locale: en
        )
        #expect(start.hasPrefix("Start failed"))
        #expect(start.contains("/Volumes/data"))
    }

    /// zh-Hans 目录命中（codex #5 高价值面）：动作错误的插值串整句 exact。
    @Test("zh-Hans：restart 半失败整句命中目录，非 key 回显")
    func restartHalfFailureZhHans() {
        let message = ContainerActionPresentation.message(
            for: .restartStartFailed(.runtimeUnavailable),
            locale: zhHans
        )
        #expect(message == "已停止，但启动失败：容器运行时没在运行")
    }
}
