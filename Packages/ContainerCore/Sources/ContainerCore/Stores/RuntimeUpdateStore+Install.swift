import Foundation

/// 升级流水线、收尾真值表、复原与崩溃恢复（Plan §5.3 / §5.4 / AD3 / AD6 / AD9）。
extension RuntimeUpdateStore {

    /// 恢复流程等 root 任务结束的轮询间隔与上限（root 自己的上限是 300 秒 + installer 时长）。
    static let jobPollInterval: TimeInterval = 5
    static let jobPollLimit = 720

    // MARK: - 升级

    func runInstall(_ release: RuntimeRelease, from installed: RuntimeVersion, op: Int) async {
        let lock = await environment.commands.privilegedJobState()
        // 准备阶段（下载 / 校验 / 等授权）不算 committed，退出会取消我们：之后不再往下走、不写状态（R7）——
        // 否则退出放行之后照样去下 118 MB 的包、起 pkgutil 校验。
        guard op == operation, !Task.isCancelled else { return }
        switch lock {
        case .running: return fail(.anotherJobRunning, op: op)
        case .probeFailed(let code): return fail(.lockProbeFailed(code), op: op)
        case .idle: break
        }

        let file: URL
        do {
            file = try await environment.downloader.download(release)
        } catch {
            // 下载被取消而抛错：那不是下载失败，是我们在退出。
            guard !Task.isCancelled else { return }
            return fail(.download(error), op: op)
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        guard op == operation, !Task.isCancelled else { return }

        setStage(.verifying, op: op)
        let verification = await environment.verifier.verify(file, expected: release.packageSHA256)
        guard verification == .ok else { return fail(.verification(verification), op: op) }
        guard op == operation, !Task.isCancelled else { return }

        setStage(.awaitingAuthorization, op: op)
        let nonce = UUID()
        // 上一次没收完的复原义务（运行时被我们停着、升级前在跑）原样带进新记录并立刻落盘（R2 E）：
        // 新任务无论成败都照样背着它——崩在 ready 之前，下次启动的恢复流程照样会起运行时、拉容器。
        // 「起运行时」是否已解除也一起带上（R4 E：纯容器欠账被继承后不会复活成「起运行时」）。
        let pending = unresolvedStop
        readyReached = false
        recordIntent(UpdateIntent(
            nonce: nonce, target: release.version, from: installed,
            runtimeWasRunning: pending != nil, stopIssued: pending != nil,
            runningContainerIDs: pending?.runningContainerIDs ?? [],
            managedContainerIDs: pending?.managedContainerIDs ?? [],
            startDischarged: pending?.startDischarged ?? false
        ))
        environment.log.jobStarted(nonce: nonce, target: release.version, from: installed, digest: release.packageSHA256)

        let outcome = await environment.installer.run(
            package: file,
            digest: release.packageSHA256,
            version: release.version,
            nonce: nonce,
            prompt: environment.authorizationPrompt(installed, release.version),
            onReady: { [weak self] in await self?.handleReady(op: op) }
        )
        environment.log.jobFinished(nonce: nonce, outcome: outcome)
        await finalize(outcome, release: release, op: op)
    }

    /// 本次操作的意图记录：内存与 defaults 一起写（L8：收尾只读内存那份）。`nil` = 清掉。
    ///
    /// **纯容器欠账只活在本次会话**（R4 E）：「起运行时」已解除的义务不落盘——磁盘上的义务永远带着一个活的「起运行时」义务。
    /// 于是重启之后既不会替谁起一个用户有意停着的运行时，也不会把几天前的容器拉起来、重报旧失败。
    func recordIntent(_ intent: UpdateIntent?) {
        activeIntent = intent
        preferences.intent = intent.flatMap { $0.hasObligation && $0.startDischarged ? nil : $0 }
    }

    /// root 已授权且复验通过（状态文件出现）。**此刻**才读运行时状态与快照（用户可能在密码框前停留很久），
    /// 把它们与 `stopIssued = true` 一起写进意图记录，**然后**才 stop（AD3 / AD9：记录先于动作）。
    /// 没有本次的意图记录就不 stop——root 等不到运行时停下会 stop-timeout，什么都不装（宁可白授权一次，不停没记录的机）。
    ///
    /// **先读、后进 committed**（R4 第 3 轮）：冻结白名单要先排空写入链，而那条链可能卡在文件系统上。读的这一段仍是
    /// awaitingAuthorization（非 committed）——退出会取消我们、立即放行，卡住的读随进程泄漏掉；进入 committed 之后只剩有界的 stop。
    ///
    /// **取消在读完之后再查一次**（R2 D）：驱动器读到 ready 之后要跳回 MainActor 才进得来，这一跳可以排在 App 退出之后；
    /// 三次读又各是一个窗口。这里的检查与 `setStage(.stoppingRuntime)` 在 MainActor 上同步连续——
    /// 要么先被取消、直接返回，要么先进入 committed、退出就得等它做完。
    ///
    /// 继承来的义务（R2 E）：`stopIssued` / `runtimeWasRunning` 只会从 false 变 true、不会被这次的读数改回 false；
    /// 容器快照取并集（= 所有被本 App 停下、还没拉回的容器）；冻结白名单取**这一次**停机时的值（归属以最新白名单为准）。
    func handleReady(op: Int) async {
        guard op == operation, !Task.isCancelled, activeIntent != nil else { return }
        readyReached = true

        let wasRunning = await environment.commands.isRuntimeRunning()
        var running: [ContainerID] = []
        if wasRunning {
            switch await environment.commands.runningContainerIDs() {
            case .success(let ids):
                running = ids
            case .failure:
                // 附录 C4（R-U9）fail-closed：运行时在跑却读不到在跑容器 ⇒ 不停机、不写 stopIssued。明知拉不回还先停掉，
                // 事后再道歉不是修复。root 等不到停机会 stop-timeout，什么都不装（T13 ⑤ 真机验证过的同一条路径）。
                // **立刻**放弃、不再读白名单：那次读要先排空写入链，可能卡在文件系统上——卡住时界面会一直停在「等待授权」（codex 实施评审 P1）。
                guard op == operation, !Task.isCancelled, let intent = activeIntent else { return }
                abandonedOperation = op
                environment.log.snapshotUnavailable(nonce: intent.nonce)
                setStage(.abandoning, op: op)
                return
            }
        }
        let managed = await environment.managedContainerIDs()

        guard op == operation, !Task.isCancelled, var intent = activeIntent else { return }
        setStage(.stoppingRuntime, op: op)

        let inherited = intent.hasObligation
        intent.runtimeWasRunning = wasRunning || inherited
        intent.stopIssued = wasRunning || inherited
        // 这一次又停了一个在跑的运行时 ⇒ 欠一次新的「起运行时」；否则沿用继承来的（已解除的不复活，R4 E）。
        if wasRunning { intent.startDischarged = false }
        intent.runningContainerIDs = intent.runningContainerIDs + running.filter { !intent.runningContainerIDs.contains($0) }
        intent.managedContainerIDs = managed.sorted { $0.rawValue < $1.rawValue }
        recordIntent(intent)
        environment.log.jobReady(
            nonce: intent.nonce, runtimeWasRunning: wasRunning, stopIssued: intent.stopIssued, runningContainers: running.count
        )

        // stop 的退出码只作诊断：装不装由 root 按客观状态定（附录 A N7）。
        if wasRunning { _ = await environment.commands.stopRuntime() }
        setStage(.installing, op: op)
    }

    /// 收尾真值表（§5.4）。结果只看 root 的输出（AD8）；要不要复原只看本次的意图记录（L8）。
    ///
    /// **被取消就什么都不写**（R5 P2-3，与 R4 A 对齐）：任务只会在非 committed 阶段被退出取消（ready 之前）；之后 root 才结束
    /// （例如用户在退出后才点了授权）——此刻起运行时 / 拉容器都发生在「退出已放行」之后。记录在盘上，留给下次启动的恢复流程。
    func finalize(_ outcome: PrivilegedJobOutcome, release: RuntimeRelease, op: Int) async {
        guard !Task.isCancelled else { return }
        let intent = activeIntent
        switch outcome {
        case .cancelled where readyReached:
            // 取消码只可能出现在授权之前；这次都走到 ready（发过 stop）了还报取消 = 没按契约结束——按 unknown 复原（安全评审 L5）。
            await restoreAfterUnexpectedEnd("(-128) after stop", intent: intent, op: op)

        case .cancelled:
            // 这次任务什么都没停过。继承来的义务（若有）原样留着——「启动运行时」仍可用，不擅自起运行时（R2 E）。
            if intent?.stopIssued != true { recordIntent(nil) }
            apply(op) { self.setState(.cancelled) }

        case .unknown(let text):
            await restoreAfterUnexpectedEnd(text, intent: intent, op: op)

        case .finished(let result, let blockers, let details):
            switch result {
            case .installed:
                setStage(.startingRuntime, op: op)
                let installed = await environment.commands.installedVersion()
                let restored = await restore(intent, op: op)
                resolveObligation(intent, after: restored)
                conclude(target: release.version, installed: installed, restored: restored, op: op)
            case .raced:
                // raced 只说明「装后证明不了没有混跑」——一个 `container system logs -f`、一次只读 mmap 都会触发，
                // 推不出「运行时被别人起来了」（R2 P0：按类别推断就会把运行时丢在停止态）。只看客观状态：
                let failure = UpdateFailure.racedDuringInstall(blockers: blockers)
                let runtimeRunning = intent?.hasObligation == true ? await environment.commands.isRuntimeRunning() : false
                // 这次 await 又是一个窗口（R5）：ready 没被驱动器看到时仍是非 committed，退出会取消我们——什么都不写。
                guard !Task.isCancelled else { return }
                if let intent, intent.hasObligation, runtimeRunning {
                    // 真有人从别处起了它（可能是旧二进制）：不代为启动、不自动补拉容器（状态可疑，不叠加副作用）。
                    // 它在跑 ⇒「起运行时」义务解除；容器欠账如实列出、只活在本次会话（R4 E；R3 P2-4 的「不静默丢掉」由列表承担）。
                    let restored = await owedWhileRunning(intent, hold: .raced, includingManaged: false)
                    // 列欠账的 `ls` 又是一个窗口（R6）：仍是非 committed，被取消就什么都不写。
                    guard !Task.isCancelled else { return }
                    resolveObligation(intent, after: restored)
                    fail(failure, pending: restored.pending, op: op)
                } else {
                    await restoreThenFail(failure, intent: intent, op: op)
                }
            default:
                // 要不要复原**只看客观的 stopIssued**（restore 内部判断），不按结果类别推断「这类失败发生在 ready 之前」——
                // 那个推断一旦不成立（codex R1 [P1]：复验失败也会写状态文件），运行时就被丢在停止状态。
                let failure = result == .stopTimeout && abandonedOperation == op
                    ? UpdateFailure.snapshotUnavailable
                    : Self.failure(for: result, blockers: blockers, details: details)
                await restoreThenFail(failure, intent: intent, op: op)
            }
        }
    }

    static func failure(for result: PrivilegedJobResult, blockers: [String], details: [String]) -> UpdateFailure {
        switch result {
        case .badArgs, .badSource, .digestMismatch, .signatureInvalid, .signerUntrusted, .unexpectedVersion, .unexpectedPayload:
            .rootVerification(result)
        case .busy: .anotherJobRunning
        case .stopTimeout: .stopTimedOut(blockers: blockers)
        case .installFailed: .installFailed(details: details)
        case .raced: .racedDuringInstall(blockers: blockers)
        case .installed, .verified, .interrupted, .error: .interrupted
        }
    }

    /// 锁不空闲 → 没复原的原因（R4 C）。
    /// 只说明「当时为什么没能复原」的失败（不是升级本身的失败）。
    static func isRestoreBlocker(_ failure: UpdateFailure) -> Bool {
        switch failure {
        case .anotherJobRunning, .lockProbeFailed, .startFailed: true
        default: false
        }
    }

    static func blocker(for lock: PrivilegedJobState) -> UpdateFailure {
        if case .probeFailed(let code) = lock { return .lockProbeFailed(code) }
        return .anotherJobRunning
    }

    /// root 没按契约结束（osascript 异常、stop 之后的取消码）：root 任务可能还活着——先等锁空闲（F23-④：osascript 被杀后
    /// root 照常跑完）。等没等到都交给 `restore`：它自己的锁闸决定动不动手——锁还被占着就不起运行时（可能新旧二进制混跑），
    /// 只如实说明（R4 C）；这里不另设一道判断（两道闸会让锁闸那一道测不到，R4 突变验证实测）。
    ///
    /// 等锁这一段**不算 committed**（R5 P2-2，与恢复流程等锁同构，R2 L）：锁可能被别的用户的任务占着，最长等一个小时——
    /// 退出（以及注销 / 关机）不能被它挡住。退出会取消我们：什么都不写，stopIssued 已在盘上，留给下次启动的恢复流程。
    /// 等完之后与进入复原（`restore` 置 committed）之间没有 await。
    private func restoreAfterUnexpectedEnd(_ text: String, intent: UpdateIntent?, op: Int) async {
        isAwaitingJobEnd = true
        let ended = await waitForJobToEnd()
        isAwaitingJobEnd = false
        // 被取消（App 在非 committed 阶段退出）：什么都不写、不发通知，记录留给下次启动（R4 A）。
        guard ended else { return }
        await restoreThenFail(.unknown(text), intent: intent, op: op)
    }

    /// 复原后以 `failure` 收尾；没复原完的如实说明欠着什么（R4 C/D）。
    private func restoreThenFail(_ failure: UpdateFailure, intent: UpdateIntent?, op: Int) async {
        let restored = await restore(intent, op: op)
        resolveObligation(intent, after: restored)
        fail(failure, pending: restored.pending, op: op)
    }

    /// installed 之后的结论（收尾与崩溃恢复共用）。菜单里的已装版本按这次实读的值刷新——**被锁挡住时也刷新**（R4 B）。
    /// 复原做完 ⇒ 版本对得上才算成功；没做完 ⇒ 报「装上了、还没复原」（不是「更新失败」，R4 B）。
    private func conclude(target: RuntimeVersion, installed: InstalledRuntime, restored: RestoreOutcome, op: Int) {
        apply(op) {
            if case .installed(let version) = installed { self.lastKnownInstalled = version }
        }
        guard installed == .installed(target) else {
            return fail(.versionMismatch(installed: installed), pending: restored.pending, op: op)
        }
        guard let pending = restored.pending else {
            apply(op) { self.setState(.succeeded(target, unrestored: restored.unrestored)) }
            return
        }
        fail(.installedButNotRestarted(target), pending: pending, op: op)
    }

    private func pollDelay() async {
        await environment.clock.sleep(until: await environment.clock.now().addingTimeInterval(Self.jobPollInterval))
    }

    /// root 级审计日志 `restored`：被取消的任务不写（R6）——那一刻的结论已被丢弃，写下来就等于说它被采纳了。
    /// committed 段里的调用不会被取消（退出等它），照写。
    func logRestored(
        nonce: UUID, leftStopped: Bool, hold: RestoreHold, startOutcome: CommandOutcome?, unrestoredContainers: Int
    ) {
        guard !Task.isCancelled else { return }
        environment.log.restored(
            nonce: nonce, leftStopped: leftStopped, hold: hold, startOutcome: startOutcome, unrestoredContainers: unrestoredContainers
        )
    }

    /// 运行时停着（我们停的、没起回来）才发通知；只欠容器时不发（R4 D：那时说「运行时停着」是假话）。
    func fail(_ failure: UpdateFailure, pending: PendingRestore? = nil, op: Int) {
        guard op == operation else { return }
        setState(.failed(failure, pending: pending))
        if case .runtimeStopped(let because) = pending { onRuntimeLeftStopped?(failure, because) }
    }

    // MARK: - 复原（AD6）

    enum RestoreOutcome: Equatable {
        /// 运行时在跑、容器拉过了（`unrestored` = 拉了但没起来的未受管容器）。
        case done(unrestored: [ContainerID])
        /// 没有要做的：没有义务；「起运行时」已解除而运行时停着（用户有意停的）；运行时在跑而什么都不欠。
        case nothingToDo
        /// 没复原完：义务留着（运行时停着 ⇒ 落盘；只欠容器 ⇒ 本次会话）。
        case pending(PendingRestore)

        var pending: PendingRestore? {
            if case .pending(let pending) = self { pending } else { nil }
        }

        var unrestored: [ContainerID] {
            if case .done(let unrestored) = self { unrestored } else { [] }
        }
    }

    /// 复原结局落到义务上（R4 E）：还清 / 无事可做 ⇒ 清；运行时还停着 ⇒ 原样留着（落盘，跨重启）；
    /// 只欠容器 ⇒ 运行时在跑、「起运行时」已解除 ⇒ 转为本次会话里的容器欠账（`recordIntent` 不落盘）。
    func resolveObligation(_ intent: UpdateIntent?, after outcome: RestoreOutcome) {
        switch outcome {
        case .done, .nothingToDo:
            recordIntent(nil)
        case .pending(.runtimeStopped):
            if let intent { recordIntent(intent) }
        case .pending(.containersNotRestarted):
            guard var intent else { return }
            intent.startDischarged = true
            recordIntent(intent)
        }
    }

    /// 我们停过、且升级前在跑 → 起运行时，再拉回升级前在跑的未受管容器。其余情况什么都不做（原状态恢复）。
    ///
    /// - **锁空闲才动**（A8；R3 P1-1）：别的 root 任务持着锁（另一个用户的 App、被授权的孤儿密码框），它可能正在替换二进制——
    ///   此刻 system start = 新旧混跑。不起运行时、不拉容器，义务留着，如实说明（R4 C/D）。
    /// - **只为撤销自己的 stop 去起运行时**（R4 E）：「起运行时」义务已解除而它停着 ⇒ 用户有意停的，不起。
    /// - `includingManaged`：恢复 / 手动路径——App 冷启动时 supervisor 走 baseline、不会自己拉白名单，拉完未受管容器后
    ///   **在 committed 段之内**请它补一次（R4 G：退出要么等请求送达，要么已在 committed 之前取消了我们）。
    func restore(_ intent: UpdateIntent?, op: Int, includingManaged: Bool = false) async -> RestoreOutcome {
        guard let intent, intent.hasObligation else { return .nothingToDo }
        // 先置 committed 再探锁：退出要么等这一步，要么已在它之前取消了我们。
        isRestoringRuntime = true
        defer { isRestoringRuntime = false }

        let lock = await environment.commands.privilegedJobState()
        guard lock == .idle else {
            return await held(lock: lock, intent: intent, userInitiated: false, includingManaged: includingManaged)
        }
        return await restoreWithLockIdle(intent, op: op, userInitiated: false, includingManaged: includingManaged)
    }

    /// 锁已确认空闲、已在 committed 段内（调用方负责）。
    private func restoreWithLockIdle(
        _ intent: UpdateIntent, op: Int, userInitiated: Bool, includingManaged: Bool
    ) async -> RestoreOutcome {
        var startOutcome: CommandOutcome?
        if !(await environment.commands.isRuntimeRunning()) {
            guard intent.owesRuntimeStart || userInitiated else {
                logRestored(nonce: intent.nonce, leftStopped: false, hold: .startDischarged, startOutcome: nil, unrestoredContainers: 0)
                return .nothingToDo
            }
            setStage(.startingRuntime, op: op)
            let outcome = await environment.commands.startRuntime()
            startOutcome = outcome
            guard outcome == .succeeded else {
                logRestored(nonce: intent.nonce, leftStopped: true, hold: .startFailed, startOutcome: outcome, unrestoredContainers: 0)
                return .pending(.runtimeStopped(because: .startFailed(outcome)))
            }
        }
        setStage(.restoringContainers, op: op)
        let unrestored = await restoreContainers(intent)
        if includingManaged, !(await requestManagedReconcile()) {
            // 请求没在上限内送达（白名单写入链卡住）：快照里此刻不在跑的容器（受管的也算）还欠着（R4 第 3 轮 (b)）——
            // 对照此刻在跑的列表（R5 P2-4：受管的可能早被 supervisor 拉起来了）。
            // 重启 App 后由 supervisor 既有的冷启动 baseline 提示接手（「N 个受管容器未运行」——告知不代劳）。
            let owed = await owedContainers(intent, includingManaged: true)
            logRestored(
                nonce: intent.nonce, leftStopped: false, hold: .reconcileRequestTimedOut, startOutcome: startOutcome, unrestoredContainers: owed.count
            )
            return owed.isEmpty ? .nothingToDo : .pending(.containersNotRestarted(owed))
        }
        logRestored(
            nonce: intent.nonce, leftStopped: false, hold: .none, startOutcome: startOutcome, unrestoredContainers: unrestored.count
        )
        return .done(unrestored: unrestored)
    }

    /// 没能动手（锁不空闲）：看一眼运行时此刻是否在跑（只读），如实说明欠着什么（R4 C/D）。
    /// 在跑 ⇒ 只欠容器（「起运行时」随之解除）；停着 ⇒ 运行时停着，原因 = 锁——除非「起运行时」已解除而不是用户按的按钮
    /// （那是用户有意停着的运行时，不归我们，R4 E）。
    /// 收的是锁状态本身，原因与日志字段都从它派生（R5 P2-8：一个来源，不在两处各映射一次）。
    private func held(
        lock: PrivilegedJobState, intent: UpdateIntent?, userInitiated: Bool, includingManaged: Bool
    ) async -> RestoreOutcome {
        guard let intent, intent.hasObligation else { return .nothingToDo }
        let blocker = Self.blocker(for: lock)
        let hold: RestoreHold = switch lock {
        case .probeFailed: .lockProbeFailed
        case .running, .idle: .lockHeld   // idle 走不到这里（调用方只在锁不空闲时调）
        }
        if await environment.commands.isRuntimeRunning() {
            return await owedWhileRunning(intent, hold: hold, includingManaged: includingManaged)
        }
        guard intent.owesRuntimeStart || userInitiated else {
            logRestored(nonce: intent.nonce, leftStopped: false, hold: .startDischarged, startOutcome: nil, unrestoredContainers: 0)
            return .nothingToDo
        }
        logRestored(nonce: intent.nonce, leftStopped: true, hold: hold, startOutcome: nil, unrestoredContainers: 0)
        return .pending(.runtimeStopped(because: blocker))
    }

    /// 运行时在跑、但我们这次不拉容器（锁不空闲 / raced 状态可疑）：欠着的容器如实列出（R4 D；恢复 / 手动路径连受管的一起列——
    /// 那时 supervisor 走 baseline，不会自己拉）。列表为空 ⇒ 什么都不欠。
    private func owedWhileRunning(_ intent: UpdateIntent, hold: RestoreHold, includingManaged: Bool) async -> RestoreOutcome {
        let owed = await owedContainers(intent, includingManaged: includingManaged)
        logRestored(nonce: intent.nonce, leftStopped: false, hold: hold, startOutcome: nil, unrestoredContainers: owed.count)
        return owed.isEmpty ? .nothingToDo : .pending(.containersNotRestarted(owed))
    }

    /// 快照里在跑、此刻不在跑的容器：未受管的；`includingManaged` 时连冻结白名单里的一起。`ls` 失败按「都不在跑」算（宁可多列）。
    private func owedContainers(_ intent: UpdateIntent, includingManaged: Bool) async -> [ContainerID] {
        let managed = Set(intent.managedContainerIDs)
        let candidates = includingManaged ? intent.runningContainerIDs : intent.runningContainerIDs.filter { !managed.contains($0) }
        guard !candidates.isEmpty else { return [] }
        let current = Set((try? await environment.commands.runningContainerIDs().get()) ?? [])
        return candidates.filter { !current.contains($0) }
    }

    /// 请 supervisor reconcile 白名单，**有上限**（R4 第 3 轮 (b)）：它在 committed 段里、退出会等它——白名单写入链卡在文件系统上时
    /// 不能把退出一起冻住。`XPCTimeout` 是 continuation + 不等：挂死的请求泄漏掉。
    /// - Returns: 请求是否在上限内送达（生产上 = `forceReconcile` 已被 supervisor 同步接受）。
    private func requestManagedReconcile() async -> Bool {
        let request = environment.requestManagedReconcile
        do {
            try await XPCTimeout.race(after: environment.reconcileRequestLimit) { await request() }
            return true
        } catch {
            return false
        }
    }

    /// 「快照 − 冻结的白名单」里此刻不在跑的，**并发**逐个 `container start`；最后以在跑列表为准报告（AD6）。
    /// 已启用的白名单归 supervisor——两个启动者不抢同一个容器。
    func restoreContainers(_ intent: UpdateIntent) async -> [ContainerID] {
        let managed = Set(intent.managedContainerIDs)
        let targets = intent.runningContainerIDs.filter { !managed.contains($0) }
        guard !targets.isEmpty else { return [] }

        let commands = environment.commands
        let current = Set((try? await commands.runningContainerIDs().get()) ?? [])
        await withTaskGroup(of: Void.self) { group in
            for id in targets where !current.contains(id) {
                group.addTask { _ = await commands.startContainer(id) }
            }
        }
        let after = Set((try? await commands.runningContainerIDs().get()) ?? [])
        return targets.filter { !after.contains($0) }
    }

    /// 等 root 任务结束（锁不再被占着），最多 `jobPollLimit` 轮。
    /// - Returns: `false` = 不再等、调用方什么都不许做：被取消（App 在非 committed 阶段退出，已放行），**或**退出已经开始而锁还被占着
    ///   （R7 C：退出在 committed 时就开始等这个任务，任务随后才转进这段不算 committed 的等锁——不放手，退出会被挡最长约一小时；
    ///   stopIssued 已在盘上，留给下次启动的恢复流程）；
    ///   `true` = 等完了（空闲 / 探不清 / 等太久）——动不动手由 `restore` 的锁闸决定。
    func waitForJobToEnd() async -> Bool {
        for _ in 0..<Self.jobPollLimit {
            // 生产时钟的 sleep 被取消后立即返回——不查就会连起几百个 lockf（R3 P2-1）。
            if Task.isCancelled { return false }
            let lock = await environment.commands.privilegedJobState()
            // 取消可能落在这次探锁的 await 里（R4 A）：此刻查，与调用方进入 committed 同步连续。
            if Task.isCancelled { return false }
            guard lock == .running else { return true }
            if isTerminating { return false }
            await pollDelay()
        }
        // 最后一轮的 sleep 之后直接出循环：取消若落在这次 sleep 里（生产时钟被取消即返回），这里是唯一还能看见它的地方（codex R6 P1）。
        return !Task.isCancelled
    }

    // MARK: - 手动「启动运行时」

    /// 用户显式意图：运行时停着就起，不看「起运行时」义务是否已解除（R4 E）；拉完未受管容器后也请受管 reconcile（R4 D：
    /// App 冷启动时运行时已在跑，supervisor 走 baseline，不会自己拉）。
    /// 没做完 → 如实说明原因（R4 C：不再静默回原态）；原状态是失败就保留原失败的文案，只更新欠账。
    func runManualStart(op: Int, restoring previous: State) async {
        let lock = await environment.commands.privilegedJobState()
        // 取消可能落在上面那次探锁的 await 里（R3 P2-1）：查取消与进入 committed 同步连续。
        guard !Task.isCancelled else { return }
        guard let intent = unresolvedStop else {
            apply(op) { self.setState(previous) }
            return
        }

        let restored: RestoreOutcome
        if lock == .idle {
            isRestoringRuntime = true
            restored = await restoreWithLockIdle(intent, op: op, userInitiated: true, includingManaged: true)
            isRestoringRuntime = false
        } else {
            restored = await held(lock: lock, intent: intent, userInitiated: true, includingManaged: true)
            // 锁忙这一路不算 committed，退出会取消我们：`held` 里的 await 返回之后什么都不许写、不发通知，记录留给下次启动（codex R5 补评 P2）。
            guard !Task.isCancelled else { return }
        }
        resolveObligation(intent, after: restored)

        guard let pending = restored.pending else {
            apply(op) { self.setState(.idle) }
            return
        }
        let failure: UpdateFailure
        if case .failed(let original, _) = previous {
            failure = original
        } else if case .runtimeStopped(let because) = pending {
            failure = because
        } else {
            failure = lock == .idle ? .interrupted : Self.blocker(for: lock)
        }
        fail(failure, pending: pending, op: op)
    }

    // MARK: - supervisor 看到运行时在跑（R4 E-6'）

    /// 触发之后的新鲜探测才是证据（见 `runtimeMayHaveRestarted`）。
    func confirmRuntimeRestarted(_ intent: UpdateIntent, op: Int) async {
        guard await environment.commands.isRuntimeRunning() else { return }
        // 会话里在跑的运行时，supervisor 看见了这次换代边沿（会话内它不是冷启动 baseline），受管的由它拉；这里只剩未受管的欠账。
        let owed = await owedContainers(intent, includingManaged: false)
        // 跨过两次 await：重新证明还活在同一个世界里——没有新操作开始（任何检查 / 升级 / 恢复 / 手动启动都经 `beginOperation`，
        // 号一定变；不再另查 busy：两道闸会让这一道测不到）、还是同一份仍值得确认的义务（`needsRestartConfirmation`）。
        // 退出会取消这个任务（它不置 busy，R6）：取消之后什么都不写。
        guard !Task.isCancelled, op == operation, let current = activeIntent, current.nonce == intent.nonce, needsRestartConfirmation(current) else {
            return
        }
        let outcome: RestoreOutcome = owed.isEmpty ? .nothingToDo : .pending(.containersNotRestarted(owed))
        logRestored(nonce: current.nonce, leftStopped: false, hold: .observedRunning, startOutcome: nil, unrestoredContainers: owed.count)
        resolveObligation(current, after: outcome)
        guard case .failed(let failure, .runtimeStopped?) = state else { return }
        if outcome.pending == nil {
            // 装上了、此刻什么都不欠 ⇒ 就是成功（R5 P2-8：不留一个没有欠账的红色失败态）。
            if case .installedButNotRestarted(let version) = failure { return setState(.succeeded(version, unrestored: [])) }
            // 主失败只是「当时没能复原」的阻挡原因（手动启动 / 恢复被锁挡住、起失败）：运行时已起、什么都不欠，这句话就过期了（R7 E）。
            if Self.isRestoreBlocker(failure) { return setState(.idle) }
        }
        setState(.failed(failure, pending: outcome.pending))
    }

    // MARK: - 崩溃恢复（AD9）

    func runRecovery(_ intent: UpdateIntent, op: Int) async {
        activeIntent = intent

        for _ in 0..<Self.jobPollLimit {
            // 等锁这一段不算 committed：退出会取消我们——立即放手，记录留着下次再恢复（R2 L）。
            if Task.isCancelled { return }
            let lock = await environment.commands.privilegedJobState()
            // 取消可能落在这次探锁的 await 里（R3 P2-1）：此刻查、与进入复原同步连续（finishRecovery 到 restore 置 committed 之间无 await）。
            guard !Task.isCancelled else { return }
            switch lock {
            case .idle:
                return await finishRecovery(intent, op: op)
            case .probeFailed:
                return await recoveryHeld(lock: lock, intent: intent, op: op)
            case .running:
                await pollDelay()
            }
        }
        // 同 `waitForJobToEnd`：取消落在最后一轮的 sleep 里，出循环后只有这里还看得见（codex R6 P1）。
        guard !Task.isCancelled else { return }
        await recoveryHeld(lock: .running, intent: intent, op: op)
    }

    /// 恢复流程等不到锁空闲：不动手，如实说明（R4 C/D），义务按 E 的规则留着。没有义务 ⇒ 记录原样留着，下次再恢复。
    private func recoveryHeld(lock: PrivilegedJobState, intent: UpdateIntent, op: Int) async {
        let blocker = Self.blocker(for: lock)
        guard intent.hasObligation else { return fail(blocker, op: op) }
        let restored = await held(lock: lock, intent: intent, userInitiated: false, includingManaged: true)
        // 同手动启动的锁忙路径（codex R5 补评 P2）：不算 committed，被取消就什么都不写。
        guard !Task.isCancelled else { return }
        resolveObligation(intent, after: restored)
        fail(blocker, pending: restored.pending, op: op)
    }

    private func finishRecovery(_ intent: UpdateIntent, op: Int) async {
        let stateFile = environment.installer.readStateFile(nonce: intent.nonce)
        environment.log.recovering(nonce: intent.nonce, stopIssued: intent.stopIssued, stateFile: stateFile)
        guard intent.stopIssued else {
            // 从未发 stop：运行时没被我们动过，无事可做。
            recordIntent(nil)
            apply(op) { self.setState(.idle) }
            return
        }

        // App 冷启动时 supervisor 走 baseline、不会自己拉白名单——restore 在 committed 段内请它补一次（AD6 / R4 G）。
        let restored = await restore(intent, op: op, includingManaged: true)
        resolveObligation(intent, after: restored)

        let installed = await environment.commands.installedVersion()
        // committed 已随 `restore` 结束，这次读版本是非 committed 的窗口（R6）：被取消就不写状态、不发通知——义务已按复原结局落盘。
        guard !Task.isCancelled else { return }
        switch stateFile {
        case .done(.installed):
            conclude(target: intent.target, installed: installed, restored: restored, op: op)
        case .done(let result?):
            fail(Self.failure(for: result, blockers: [], details: []), pending: restored.pending, op: op)
        case .done(nil), .ready, nil:
            fail(.interrupted, pending: restored.pending, op: op)
        }
    }
}
