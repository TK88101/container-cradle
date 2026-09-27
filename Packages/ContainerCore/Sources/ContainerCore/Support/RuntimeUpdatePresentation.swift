import Foundation

/// 运行时更新器的全部上屏文案（Day 22 T9）。判断与措辞住 core（可测）；app 只负责画。
///
/// 纪律：**「没查到」绝不读起来像「已是最新」**（Plan §4 / A4）；技术细节（HTTP 码、stderr 末尾、路径）原样透传不翻译
/// （Day 14 §1：技术详情保持可搜索）。
public enum RuntimeUpdatePresentation {

    // MARK: - 菜单状态行

    /// `idle` 不占行（菜单里只剩版本行与按钮）。
    public static func statusText(for state: RuntimeUpdateStore.State, locale: Locale = .current) -> String? {
        switch state {
        case .idle:
            return nil
        case .checking:
            return String(coreLocalized: "Checking for updates…", locale: locale)
        case .upToDate(let version):
            return String(coreLocalized: "apple/container \(version.description) is up to date", locale: locale)
        case .available(let installed, let release):
            return String(coreLocalized: "apple/container \(release.version.description) is available (installed: \(installed.description))", locale: locale)
        case .skipped(_, let release):
            return String(coreLocalized: "Skipped apple/container \(release.version.description)", locale: locale)
        case .notInstalled:
            return String(coreLocalized: "apple/container is not installed", locale: locale)
        case .checkFailed(let failure):
            return checkFailureText(failure, locale: locale)
        case .updating(let release, let stage):
            return stageText(stage, target: release.version, locale: locale)
        case .recovering:
            return String(coreLocalized: "Finishing the previous update…", locale: locale)
        case .succeeded(let version, let unrestored):
            guard !unrestored.isEmpty else {
                return String(coreLocalized: "Updated to apple/container \(version.description)", locale: locale)
            }
            let names = unrestored.map(\.rawValue).joined(separator: ", ")
            return String(coreLocalized: "Updated to apple/container \(version.description). Could not restart: \(names)", locale: locale)
        case .cancelled:
            return String(coreLocalized: "Update cancelled", locale: locale)
        case .failed(let failure, let pending):
            return failedText(failure, pending: pending, locale: locale)
        case .otherInstanceActive:
            return String(coreLocalized: "Another Container Cradle instance is managing runtime updates.", locale: locale)
        }
    }

    /// 失败 + 还欠着什么（R4 B/C/D）。原因与主失败相同时不重复（例如手动启动被锁挡住：主失败就是「另一个更新正在进行」）。
    /// 标点纪律：`failureText` 一律**不带句末标点**，句与句之间的标点由这里的模板负责（否则拼出「。。」「。；」「..」，守卫测试穷举）。
    static func failedText(_ failure: UpdateFailure, pending: PendingRestore?, locale: Locale) -> String {
        let text = failureText(failure, locale: locale)
        switch pending {
        case nil:
            return text
        case .runtimeStopped(let because)?:
            guard because != failure else {
                return String(coreLocalized: "\(text). The runtime is stopped.", locale: locale)
            }
            let reason = failureText(because, locale: locale)
            return String(coreLocalized: "\(text). The runtime is stopped: \(reason).", locale: locale)
        case .containersNotRestarted(let ids)?:
            let names = ids.map(\.rawValue).joined(separator: ", ")
            return String(coreLocalized: "\(text). Not restarted yet: \(names).", locale: locale)
        }
    }

    /// 升级阶段的已用时间（`m:ss`；时钟回拨按 0 算）。真下载 118 MB 实测 206 秒——没有读数的「下载中…」看起来像卡死。
    public static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func checkFailureText(_ failure: CheckFailure, locale: Locale) -> String {
        switch failure {
        case .installedVersionUnknown(let reason):
            return String(coreLocalized: "Could not read the installed version: \(reason)", locale: locale)
        case .rateLimited(let until):
            let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            return String(coreLocalized: "GitHub rate limit reached. Try again after \(time).", locale: locale)
        case .release(.network(let message)):
            return String(coreLocalized: "Update check failed: \(message)", locale: locale)
        case .release(.http(let code)):
            return String(coreLocalized: "Update check failed (HTTP \(String(code)))", locale: locale)
        case .release(.feed(.noSignedPackage)):
            return String(coreLocalized: "The latest release has no signed installer package", locale: locale)
        case .release(.feed):
            return String(coreLocalized: "Update check failed: unexpected response from GitHub", locale: locale)
        }
    }

    static func stageText(_ stage: UpdateStage, target: RuntimeVersion, locale: Locale) -> String {
        switch stage {
        case .downloading:
            String(coreLocalized: "Downloading apple/container \(target.description)…", locale: locale)
        case .verifying:
            String(coreLocalized: "Verifying the package signature…", locale: locale)
        case .awaitingAuthorization:
            // T13 发现 #1：macOS 27 不显示 `with prompt`，密码框里只剩系统文案——版本与后果只能靠这一行说出来。
            String(coreLocalized: "Enter your administrator password to update apple/container to \(target.description). The runtime and its running containers will restart.", locale: locale)
        case .stoppingRuntime:
            String(coreLocalized: "Stopping the runtime…", locale: locale)
        case .installing:
            String(coreLocalized: "Installing apple/container \(target.description)…", locale: locale)
        case .startingRuntime:
            String(coreLocalized: "Starting the runtime…", locale: locale)
        case .abandoning:
            String(coreLocalized: "Could not read the running containers, so the runtime was not stopped. Waiting for the installer to give up…", locale: locale)
        case .restoringContainers:
            String(coreLocalized: "Restarting containers…", locale: locale)
        }
    }

    public static func failureText(_ failure: UpdateFailure, locale: Locale = .current) -> String {
        switch failure {
        case .snapshotUnavailable:
            return String(coreLocalized: "Update not performed: could not read the running containers before stopping the runtime. Nothing was stopped or installed", locale: locale)
        case .anotherJobRunning:
            return String(coreLocalized: "Another update is already in progress", locale: locale)
        case .lockProbeFailed(let code):
            return String(coreLocalized: "Could not tell whether another update is running (lockf \(String(code)))", locale: locale)
        case .installedButNotRestarted(let version):
            return String(coreLocalized: "apple/container \(version.description) was installed", locale: locale)
        case .download(.http(let code)):
            return String(coreLocalized: "Download failed (HTTP \(String(code)))", locale: locale)
        case .download(.sizeMismatch):
            return String(coreLocalized: "Download failed: the file size does not match", locale: locale)
        case .download(.network(let message)), .download(.filesystem(let message)):
            return String(coreLocalized: "Download failed: \(message)", locale: locale)
        case .verification(.digestMismatch):
            return String(coreLocalized: "The downloaded package does not match the published checksum", locale: locale)
        case .verification(.signature):
            return String(coreLocalized: "The package is not signed by Apple (team \(PackageSignature.teamID))", locale: locale)
        case .verification(.unreadable), .verification(.ok):
            return String(coreLocalized: "The downloaded package could not be read", locale: locale)
        case .rootVerification(let result):
            return String(coreLocalized: "Verification failed during installation (\(result.rawValue))", locale: locale)
        case .stopTimedOut(let blockers):
            let names = blockers.isEmpty ? "?" : blockers.joined(separator: ", ")
            return String(coreLocalized: "The runtime did not stop in time; nothing was installed. Still running: \(names)", locale: locale)
        case .installFailed(let details):
            let detail = details.isEmpty ? "?" : fragment(details.joined(separator: ", "))
            return String(coreLocalized: "The installer failed (\(detail))", locale: locale)
        case .racedDuringInstall(let blockers):
            // 不断言「运行时被别人起来了」——raced 只说明装后证明不了没有混跑（R2）。
            let names = blockers.isEmpty ? "?" : blockers.joined(separator: ", ")
            return String(coreLocalized: "Right after installing, some runtime files were still in use (\(names)). If the runtime misbehaves, run the update again", locale: locale)
        case .versionMismatch(let installed):
            return String(coreLocalized: "The installed version is not the expected one (\(installedText(installed)))", locale: locale)
        case .startFailed:
            return String(coreLocalized: "The runtime could not be started", locale: locale)
        case .unknown(let text):
            return String(coreLocalized: "The update ended unexpectedly: \(fragment(text))", locale: locale)
        case .interrupted:
            return String(coreLocalized: "The previous update was interrupted", locale: locale)
        }
    }

    /// 不可信文本（osascript stderr 的尾巴、root 的 COF_DETAIL）可能自带句末标点：拼进模板之前剥掉——句间标点只由模板负责
    /// （R5 P2-9：否则拼出「..」「.。」，而标点守卫的夹具若只用常量就看不见）。
    static func fragment(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace || "．.。".contains(last) { result = result.dropLast() }
        return String(result)
    }

    private static func installedText(_ installed: InstalledRuntime) -> String {
        switch installed {
        case .installed(let version): version.description
        case .notInstalled: "—"
        case .unknown(let reason): reason
        }
    }

    // MARK: - A9：未经测试的运行时版本

    /// 已装版本 ≠ 本 App 构建时 pin 的上游版本 → 一行非阻断提示。
    public static func testedNote(installed: RuntimeVersion?, tested: RuntimeVersion, locale: Locale = .current) -> String? {
        guard let installed, installed != tested else { return nil }
        return String(coreLocalized: "Container Cradle was built and tested with apple/container \(tested.description)", locale: locale)
    }

    // MARK: - 系统通知

    /// key 带版本、同版本稳定：它就是通知请求的 identifier ⇒ 次日再提醒时新通知替换旧的（不去重，R2 G；节流在 store / 调度器）。
    public static func availableNotification(
        release: RuntimeRelease, installed: RuntimeVersion, locale: Locale = .current
    ) -> SystemNotificationContent {
        SystemNotificationContent(
            key: "runtimeUpdate.available:\(release.version.description)",
            title: String(coreLocalized: "apple/container \(release.version.description) is available", locale: locale),
            body: String(coreLocalized: "Installed: \(installed.description). The runtime and running containers restart during the update.", locale: locale)
        )
    }

    /// 运行时被我们停着、没起回来（只在 `.runtimeStopped` 时发，R4 D）。装上了只是没复原的，标题不说「更新失败」（R4 B）。
    public static func runtimeLeftStoppedNotification(
        failure: UpdateFailure, because: UpdateFailure, locale: Locale = .current
    ) -> SystemNotificationContent {
        let title: String = if case .installedButNotRestarted(let version) = failure {
            String(coreLocalized: "apple/container \(version.description) was installed", locale: locale)
        } else {
            String(coreLocalized: "apple/container update failed", locale: locale)
        }
        let status = failedText(failure, pending: .runtimeStopped(because: because), locale: locale)
        return SystemNotificationContent(
            key: "runtimeUpdate.leftStopped:\(UUID().uuidString)",
            title: title,
            body: String(coreLocalized: "\(status) Open the menu to start it.", locale: locale)
        )
    }

    // MARK: - 系统密码框

    public static func authorizationPrompt(from: RuntimeVersion, to: RuntimeVersion, locale: Locale = .current) -> String {
        String(coreLocalized: "Container Cradle wants to update apple/container from \(from.description) to \(to.description). The runtime and its running containers will restart.", locale: locale)
    }
}
