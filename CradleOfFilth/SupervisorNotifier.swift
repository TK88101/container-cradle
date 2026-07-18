import ContainerCore
import Foundation
import os
import UserNotifications

/// **把「supervisor 停手了」推到用户眼前。** Day 8。
///
/// 熔断 / 放弃的语义是「从此不会自动好转」——而 supervisor 不干活的样子和一切正常一模一样。
/// 只在菜单栏图标上变个形不够：**用户不会为了看图标而去看菜单栏**。所以要发系统通知。
///
/// ## 它刻意很薄
///
/// **哪些 notice 该弹、弹什么话、怎么去重**全是判断，住在 core 的
/// `SupervisorPresentation.notification(for:)`（那儿有测试）。这里只做 core 做不了的事：
/// 真的调 `UNUserNotificationCenter`。判断一行都不在这儿——app target 没有测试 target。
///
/// 消费的是 `SupervisorStatusStore.onNotices` 那条**事件流**（本次快照带来的 notices），
/// 不是留存态 `lastNotice`（codex P1-7：从留存态反推会把旧通知当新事件重弹）。
@MainActor
final class SupervisorNotifier {

    private let center = UNUserNotificationCenter.current()

    /// **同 key 只弹一次**（判断住 core，可测）。key 带 generation，换代后自然能再弹。
    private var dedup = NotificationDeduplicator()

    /// 通知这条线自己的日志。授权失败必须可观测——否则 Day 8 的可观测性目标在这里打折
    /// （codex P1-8：用户拒授权后，静默降级可接受，但日志里得看得见）。
    private let log = Logger(subsystem: SupervisorLogging.subsystem, category: "notify")

    /// 请求通知授权。**只请求一次**，拒绝就静默降级（菜单栏图标 + 菜单里的说明仍在）。
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            if let error {
                log.error("通知授权失败：\(error.localizedDescription, privacy: .public)")
            } else if !granted {
                log.notice("用户拒绝了通知授权——降级为菜单栏图标 + 菜单说明")
            }
        }
    }

    /// 处理一批 notice。非「必须人介入」的（成功 / 过程态失败 / 手动不可用）由 core 判成 `nil`，跳过。
    func handle(_ notices: [SupervisorNotice]) {
        for notice in notices {
            guard let content = SupervisorPresentation.notification(for: notice) else { continue }
            guard dedup.shouldDeliver(content) else { continue }   // 同 key 只弹一次（判断在 core）
            post(content)
        }
    }

    private func post(_ content: SystemNotificationContent) {
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.sound = .default

        // identifier 用同一个 key：万一系统层面也重复投递，同 id 会替换而不是叠一堆。
        center.add(UNNotificationRequest(identifier: content.key, content: body, trigger: nil))
    }
}
