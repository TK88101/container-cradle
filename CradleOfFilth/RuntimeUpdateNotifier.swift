import ContainerCore
import Foundation
import os
import UserNotifications

/// 运行时更新的系统通知（Day 22，AD5）：投递「有新版」与「升级失败、运行时停着」两种通知，并接住通知上的动作。
///
/// ## 它是通知中心**唯一**的 delegate
///
/// 设 delegate 是全局副作用：`willPresent` 返回 `[.banner, .sound]` 之后，**supervisor 的熔断通知在 App 处于前台时也会显示**
/// （此前没有 delegate，前台不显示）——这正是想要的，Plan §8 影响面已登记。
///
/// **只有主实例 attach**（R3 P2-6c：两个同 bundle id 的进程都当 delegate，「立即更新」可能投给只读的那个而被吞掉）。
/// 代价（R4 H，接受）：副实例在前台时，它自己的 supervisor 通知不显示——副实例在实践中是开发机上与安装版并存的 Xcode DEBUG 构建。
/// 双实例时系统把通知动作投给哪个进程：TBD，T13 真机实测。
///
/// ## 它刻意很薄
///
/// 弹什么、怎么措辞、去重 key 全在 core（`RuntimeUpdatePresentation`，有测试）；动作落到 store 的同一组方法（单飞在那边）。
@MainActor
final class RuntimeUpdateNotifier: NSObject, UNUserNotificationCenterDelegate {

    nonisolated static let categoryID = "runtimeUpdate.available"
    nonisolated static let updateActionID = "runtimeUpdate.updateNow"
    nonisolated static let skipActionID = "runtimeUpdate.skipVersion"
    nonisolated static let versionKey = "version"

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: SupervisorLogging.subsystem, category: "runtime-update")
    private weak var store: RuntimeUpdateStore?

    /// App 启动时调用一次：成为 delegate、注册带两个动作的 category、接上 store 的两个事件。
    func attach(to store: RuntimeUpdateStore) {
        self.store = store
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [
                    UNNotificationAction(identifier: Self.updateActionID, title: String(localized: "Update Now")),
                    UNNotificationAction(identifier: Self.skipActionID, title: String(localized: "Skip This Version")),
                ],
                intentIdentifiers: []
            ),
        ])
        store.onUpdateAvailable = { [weak self] release, installed in
            self?.postAvailable(release: release, installed: installed)
        }
        store.onRuntimeLeftStopped = { [weak self] failure, because in
            self?.post(
                RuntimeUpdatePresentation.runtimeLeftStoppedNotification(failure: failure, because: because),
                category: nil, userInfo: [:]
            )
        }
    }

    private func postAvailable(release: RuntimeRelease, installed: RuntimeVersion) {
        let content = RuntimeUpdatePresentation.availableNotification(release: release, installed: installed)
        post(content, category: Self.categoryID, userInfo: [Self.versionKey: release.version.description])
    }

    /// 不去重（R2 G）：「有新版」一天最多一条，节流在 store / 调度器（≥ 24h 才检查，有测试）；在这里按版本去重会把
    /// 「稍后 = 次日再提醒」永久压掉。请求 identifier = content.key（同版本稳定）⇒ 新通知替换旧的，不会堆叠。
    private func post(_ content: SystemNotificationContent, category: String?, userInfo: [String: String]) {
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.sound = .default
        body.userInfo = userInfo
        if let category { body.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: content.key, content: body, trigger: nil)) { [log] error in
            if let error { log.error("更新通知投递失败：\(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let version = response.notification.request.content.userInfo[Self.versionKey] as? String
        await route(action: action, version: version)
    }

    /// 「立即更新」→ store 有可用版本就装，否则走一次手动检查（App 可能重启过）；「跳过此版本」→ 按通知带的版本号记下。
    private func route(action: String, version: String?) {
        guard let store else { return }
        switch action {
        case Self.updateActionID:
            store.updateNow()
        case Self.skipActionID:
            if let version = version.flatMap(RuntimeVersion.init(parsing:)) { store.skip(version: version) }
        default:
            break
        }
    }
}
