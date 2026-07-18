import Foundation
import Testing

@testable import ContainerCore

/// **哪些 notice 弹系统通知、弹什么、怎么去重**——都是判断，所以住 core、有测试。
@Suite("SystemNotificationContent")
struct SystemNotificationContentTests {

    private let g1 = RuntimeGeneration(pid: 100, startTime: 1_000)
    private let g2 = RuntimeGeneration(pid: 200, startTime: 2_000)

    @Test("熔断：弹通知")
    func circuitOpenedNotifies() throws {
        let content = try #require(
            SupervisorPresentation.notification(for: .circuitOpened(generation: g1, failures: 5))
        )
        #expect(content.key == "circuitOpened:100/1000:5")
        #expect(!content.title.isEmpty)
        #expect(content.body.contains("5"))
    }

    @Test("放弃：弹通知")
    func abandonedNotifies() throws {
        let content = try #require(
            SupervisorPresentation.notification(for: .reconcileAbandoned(generation: g1))
        )
        #expect(content.key == "reconcileAbandoned:100/1000")
    }

    /// 过程态与即时反馈不弹——弹了就是噪音。
    @Test(
        "不弹的三条",
        arguments: [
            SupervisorNotice.reconcileSucceeded(generation: RuntimeGeneration(pid: 1, startTime: 1)),
            SupervisorNotice.reconcileFailed(
                generation: RuntimeGeneration(pid: 1, startTime: 1),
                kind: .environmentNotReady,
                attempt: 1,
                retryAt: Date(timeIntervalSince1970: 0)
            ),
            SupervisorNotice.forcedReconcileUnavailable,
        ]
    )
    func doesNotNotify(_ notice: SupervisorNotice) {
        #expect(SupervisorPresentation.notification(for: notice) == nil)
    }

    /// ★ 去重 key 带 generation：**换代 = 新的一件事**，key 变 → 可以再弹。
    @Test("不同世代的熔断 → 不同 key（换代后能再弹）")
    func keyVariesByGeneration() throws {
        let a = try #require(SupervisorPresentation.notification(for: .circuitOpened(generation: g1, failures: 5)))
        let b = try #require(SupervisorPresentation.notification(for: .circuitOpened(generation: g2, failures: 5)))
        #expect(a.key != b.key)
    }

    /// 同一代同一次熔断 → 同 key（`SupervisorNotifier` 据此只弹一次）。
    @Test("同世代同次数的熔断 → 同 key（只弹一次）")
    func sameEventSameKey() throws {
        let a = try #require(SupervisorPresentation.notification(for: .circuitOpened(generation: g1, failures: 5)))
        let b = try #require(SupervisorPresentation.notification(for: .circuitOpened(generation: g1, failures: 5)))
        #expect(a.key == b.key)
    }

    // MARK: - 去重器（同 key 只弹一次）

    private func content(_ key: String) -> SystemNotificationContent {
        SystemNotificationContent(key: key, title: "t", body: "b")
    }

    @Test("同 key 第二次问 → 不放行")
    func dedupBlocksSameKey() {
        var dedup = NotificationDeduplicator()
        // mutating 调用提到 #expect 外：#expect 的 autoclosure 里参数是 immutable。
        let first = dedup.shouldDeliver(content("k1"))
        let second = dedup.shouldDeliver(content("k1"))
        #expect(first)
        #expect(!second)
    }

    @Test("不同 key → 各放行一次")
    func dedupAllowsDistinctKeys() {
        var dedup = NotificationDeduplicator()
        let k1 = dedup.shouldDeliver(content("k1"))
        let k2 = dedup.shouldDeliver(content("k2"))
        let k1Again = dedup.shouldDeliver(content("k1"))
        #expect(k1)
        #expect(k2)
        #expect(!k1Again)
    }
}
