import ContainerCore
import ContainerRuntime
import Foundation
import Observation
import os

/// **Composition root。** 整个 App 里唯一决定「用哪个运行时」的地方。
///
/// Day 6 之前这里注入的是 `FakeContainerRuntimeClient.preview`——大脑（reducer）、
/// 手脚（prober / engine）、真运行时（live client）全都造好了，但**从来没接在一起过**。
/// 这个文件就是那最后一根线：`LiveContainerRuntimeClient()` 一进来，supervisor 就真的
/// 会去起容器了。
///
/// D1 的回报在这里兑现：从假运行时切到真运行时，`ContainerListStore` 和所有 view
/// **一个字都没改**——它们只认 `any ContainerRuntimeClient`。
@MainActor
@Observable
final class AppModel {

    let containers: ContainerListStore
    let status: SupervisorStatusStore
    let whitelist: WhitelistUIStore

    /// Day 13：详情页 stop/start/restart 的动作状态机。**client 不进 view**（裁决 #9）：
    /// view 拿到的是闭包 + 进行中/错误态，动作语义（拒绝制、restart 半失败区分）全在 core。
    let actions: ContainerActionStore

    /// M5（Day 10）：volume / image 管理窗口的 store。App 级单例——窗口关了再开，
    /// 列表与删除流程的状态不该凭空蒸发。
    let volumes: VolumeListStore
    let images: ImageListStore

    /// Day 16 T9b：新建容器的草稿 + 提交态机。常驻（B 段 §3.3）：单实例创建窗口关了再开，
    /// 草稿不该凭空蒸发（env 例外——明文不许长寿命，`SecretString` 不可读回，关窗即清）。
    let creationForm: ContainerCreationForm
    let creation: ContainerCreationStore

    /// Day 16 T9b：镜像 pull 态机。常驻（B 段 §3.3）：pull 可能在 sheet 关闭后仍在跑，态必须活过 UI。
    let pull: ImagePullStore

    /// 日志窗口 / stats 窗口自己起 `followLogs` / `stats` 用的同一个运行时客户端
    /// （Day 9，T7/T11）。**不是新连接**——`LiveContainerRuntimeClient` 每次调用现建 XPC
    /// 连接（D-F），这里只是把 composition root 已经持有的那份引用递出去，不引入新的生命周期。
    let client: any ContainerRuntimeClient

    /// Day 22：apple/container 运行时更新器（探测 + 升级）。App 级单例——升级可能在菜单关着时进行。
    let updates: RuntimeUpdateStore

    /// 本 App 构建时 pin 的上游版本（A9：已装版本与它不同就给一行非阻断提示）。
    var testedRuntimeVersion: RuntimeVersion { UpstreamPin.version }

    private let supervisor: Supervisor
    private let whitelistStore: WhitelistStore
    /// 更新器的单实例租约（R2 O）。**先于更新器的恢复 / 调度拿到**，持有到进程结束（fd 一关 flock 就释放）。
    /// 拿不到（另一个实例——例如 Xcode 跑的 DEBUG 构建与安装版并存——正持有）→ 本实例的更新器只读。
    private let updateLease: InstanceLease?
    private let updateScheduler: RuntimeUpdateScheduler
    private let updateNotifier = RuntimeUpdateNotifier()
    /// 启动 / 退出的编排与生命周期令牌（codex R5 补评 P1）：启动途中退出，启动的续体什么都不再做。
    private let lifecycle: AppLifecycle

    /// 熔断 / 放弃 → 系统通知（Day 8）。消费 `status.onNotices` 那条事件流。
    private let notifier = SupervisorNotifier()

    /// 白名单文件在哪。菜单里的「在 Finder 中显示」要用——
    /// 一个「用户可以手改」的配置文件，App 不告诉他在哪，那句话就是空话。
    var whitelistURL: URL { whitelistStore.url }

    init(client: any ContainerRuntimeClient = LiveContainerRuntimeClient()) {
        let store = WhitelistStore.default()
        let status = SupervisorStatusStore()

        self.whitelistStore = store
        self.status = status
        self.client = client
        self.containers = ContainerListStore(client: client)
        self.volumes = VolumeListStore(client: client)
        self.images = ImageListStore(client: client)
        self.whitelist = WhitelistUIStore(writer: store)

        // 动作结束刷新列表：闭包注入（store 不认识 ContainerListStore）。
        // 引用刚建好的 containers store——`self.containers` 已在上面完成初始化。
        let containerList = self.containers
        self.actions = ContainerActionStore(client: client) {
            await containerList.refresh()
        }

        // Day 16 T9b：创建族 + pull。pull 完成刷新镜像列表，同上闭包注入
        //（`cancel()` 刻意不触发——前台放弃不承诺列表同步，见 `ImagePullStore`）。
        self.creationForm = ContainerCreationForm()
        self.creation = ContainerCreationStore(client: client)
        let imageList = self.images
        self.pull = ImagePullStore(client: client) {
            await imageList.refresh()
        }

        // Day 8：唯一决定「决策去哪儿被记下来」的地方。engine 和 supervisor 共用同一个 log
        // → reconcile 的每一步（下达 / 成败 / 单容器失败诊断）落在同一条时间线上。
        let log = OSLogSupervisorLog()

        self.supervisor = Supervisor(
            prober: ApiserverProber(),
            engine: WhitelistReconcileEngine(client: client, whitelist: store, log: log),
            log: log,
            // `observer()` 里那个 `Task { @MainActor in }` 是本 App 最后一个跨 await 的窗口。
            // 挡住它的是快照上的 `sequence`（见 `SupervisorStatusStore.apply`）。
            observe: status.observer()
        )

        #if DEBUG
        // 截图夹具（codex R5 补评 D）：整个更新器换成惰性替身，摆出「只欠容器」那一屏。判定排在租约之前——
        // 夹具不占真租约，否则在它之后启动的正式实例会变成只读（R6 评审）。
        var fixture: RuntimeUpdateStore?
        if let ids = Self.launchArgument("COFUpdateFixtureContainerDebt") {
            fixture = UpdateScreenshotFixture.containerDebtStore(ids)
        }
        #else
        let fixture: RuntimeUpdateStore? = nil
        #endif
        if let fixture {
            self.updateLease = nil
            self.updates = fixture
        } else {
            // 只有「另一个实例持着」才只读；租约文件坏了按主实例运行并记日志（R3 P2-6a：否则唯一的实例会永久失去复原能力）。
            let claim = InstanceLease.claim(at: InstanceLease.defaultURL())
            if claim.isPrimary, let failure = claim.failure {
                Logger(subsystem: SupervisorLogging.subsystem, category: "runtime-update")
                    .error("instance lease unavailable (\(String(describing: failure), privacy: .public)); running as primary")
            }
            self.updateLease = claim.lease
            self.updates = Self.makeUpdateStore(
                supervisor: supervisor, whitelistStore: store, whitelistUI: whitelist, isPrimaryInstance: claim.isPrimary
            )
        }
        self.updateScheduler = RuntimeUpdateScheduler(store: updates, initialDelay: Self.updateInitialDelay)
        self.lifecycle = Self.makeLifecycle(
            supervisor: supervisor, whitelist: whitelist, updates: updates, scheduler: updateScheduler,
            notifier: notifier, updateNotifier: updateNotifier
        )

        // 系统通知桥接：store 在 MainActor 上把每份被采纳快照的 notices 投给 notifier
        // （已过 sequence 闸 → 迟到旧快照不会重弹；notifier 再按业务 key 去重）。
        status.onNotices = { [notifier] notices in notifier.handle(notices) }
        // supervisor 看到运行时在跑 → 只是触发；证据是更新器里另做的一次新鲜探测（R4 E-6'：快照可能生成于我们 stop 之前、晚到）。
        status.onStateApplied = { [updates] state in
            if SupervisorPresentation.generation(for: state) != nil { updates.runtimeMayHaveRestarted() }
        }

        // Day 14：本地化双哨兵。两本目录任一没接上（key 回显）就大声死在 DEBUG——
        // app target 没有测试 target，这是运行态唯一的自动守卫（codex #1 #2）。
        #if DEBUG
        assert(
            AppLocalizationProbe.bothCatalogsWired(),
            "Localization catalog not wired: core .module or app main-bundle resolves keys verbatim (key echo)."
        )
        #endif
    }

    /// App 启动。**不等菜单被点开**——supervisor 的全部价值就在于「用户没在看的时候它还在盯」。
    ///
    /// 这也是为什么它挂在 `NSApplicationDelegate` 上而不是 `MenuBarExtra` 的 `.task`：
    /// 后者只在菜单被点开时才跑。
    ///
    /// ## supervisor 先起，白名单后读（codex review 抓到的顺序问题）
    ///
    /// supervisor 探测**不需要**这份 UI 白名单——`ReconcileEngine` 直接读 `WhitelistStore`。
    /// `whitelist.load()` 纯粹是给界面用的。把它排在第一次 probe 前面，等于让一次磁盘 IO
    /// 挡在**核心场景的边沿检测**前头：Mac 重启后 App 和 apiserver 在赛跑，
    /// 这个 load 若慢了一步（网络家目录、磁盘忙），第一次 probe 就会看到「运行时已经在跑」——
    /// 于是走冷启动 baseline 路径，**什么都不拉**。那条边沿一辈子只出现一次，错过就没了。
    ///
    /// 各步的顺序与「启动途中退出」的处理在 `AppLifecycle`（core，可测）；这里只装配（`makeLifecycle`）。
    func start() async {
        await lifecycle.start()
    }

    /// App 退出。两件事，都不能省。
    ///
    /// 1. **停 supervisor**：不停的话那些睡着的 Task 会一直挂着，更糟的是
    ///    「正在退出的 App 把容器拉起来」（Day 5 的 epoch 就是为它加的）。
    ///
    /// 2. **把白名单的写入链排空**（codex review 抓到的）：勾选是**先改内存、再排队落盘**的。
    ///    用户勾完一个容器随手就退出，那次写还挂在链上——进程一没，它就没了。
    ///    界面上勾着，磁盘上没有，**下次开机 supervisor 不会拉它**，
    ///    而没有任何东西会告诉用户。核心价值又一次静默归零。
    func stop() async {
        await lifecycle.stop()
    }

    /// 退出入口的同步准备（附录 C3）：`applicationShouldTerminate` 在建 `Task {}` **之前**调——
    /// `stop()` 隔着一次调度，那一段里菜单照样收事件（T13 R6 #3 实测）。
    func beginQuit() {
        lifecycle.beginQuit()
    }

    /// 「立即启动受管容器」。**手动兜底必须存在**，而且它是**熔断的唯一出口**：
    /// 熔断之后 supervisor 不再自动重试，只有人按这一下能让它重新开始。
    ///
    /// **先把白名单的写排空，再动手**（codex review 抓到的）。
    /// 勾选是「先改内存、再排队落盘」，而 `ReconcileEngine` 读的是 `WhitelistStore`——
    /// 用户勾完一个容器**紧接着**按这个按钮，那次写可能还没落地，
    /// 于是 reconcile 按**旧白名单**执行，**恰好跳过他刚勾的那一个**。
    /// 他点了两下，什么都没发生，而界面上一切正常。
    ///
    /// 自动路径不用管：运行时换代是个未来事件，那时写早落地了。
    /// 要命的只有「勾完立刻点」这紧挨着的两下。
    func forceReconcile() async {
        await whitelist.awaitWrites()
        await supervisor.forceReconcile()
    }

    /// 当前 apiserver 的这一代（`nil` = 还没探测过，或探测确认它不在）。
    ///
    /// 日志窗口靠它做 L1'：follow 开始时记下这一代，之后每一轮发现它变了，
    /// 就说明中途死过一次——旧的 `FileHandle` 可能指向一个已经 unlink 的日志文件
    /// （`seekToEnd()` 对着死 fd 照样成功，不会报错，见 Day 9 计划 P1-5）。
    ///
    /// 转发给 `SupervisorPresentation.generation(for:)`（A3）——判断本身（穷尽 switch，
    /// 让未来新增的 `SupervisorState` case 在这里编译报错）搬进了 core，可测；
    /// 这里只剩「拿 `status.state` 去问」这一行。
    var currentGeneration: RuntimeGeneration? {
        SupervisorPresentation.generation(for: status.state)
    }

    // MARK: - 启动 / 退出装配

    /// `start()` / `stop()` 的各步（顺序与令牌在 `AppLifecycle`）。
    private static func makeLifecycle(
        supervisor: Supervisor,
        whitelist: WhitelistUIStore,
        updates: RuntimeUpdateStore,
        scheduler: RuntimeUpdateScheduler,
        notifier: SupervisorNotifier,
        updateNotifier: RuntimeUpdateNotifier
    ) -> AppLifecycle {
        AppLifecycle(steps: .init(
            beginStartup: {
                // 通知授权：现在请求，用户第一次真被弹之前就把授权拿到手。拒了就静默降级（图标 + 菜单说明）。
                notifier.requestAuthorization()
                // 副实例不接更新通知的动作（R3 P2-6c）：同 bundle id 的两个进程都当 delegate 时，「立即更新」可能被投给只读的那个而被吞掉。
                if updates.isPrimaryInstance { updateNotifier.attach(to: updates) }
            },
            startSupervisor: { await supervisor.start() },
            loadWhitelist: { await whitelist.load() },
            beginBackgroundWork: {
                // 上一次升级若没走完收尾（App 被强杀），先把它收拾好，再开始定时检查（AD9）。
                updates.recoverIfNeeded()
                scheduler.start()
            },
            beginQuit: {
                // 冻结之后的勾选没人等、退出即丢；更新器同步置 isTerminating（prepareForTermination 更晚，隔着调度）。
                whitelist.freeze()
                updates.beginTermination()
            },
            prepareForQuit: {
                // **先等升级**（Day 22）：运行时可能正被我们停着（committed 阶段）——那时退出等于把它丢在停止状态。
                //    其余阶段 `prepareForTermination` 立即放行。
                scheduler.stop()
                await updates.prepareForTermination()

                // **总是**先有界地交接给 supervisor 再停它（R2 F → R3 P2-2）：探一次（新一代由边沿检测触发 reconcile），
                // 等在途的 reconcile 跑完。只在「刚等过一次收尾」时才交接是不够的——正常升级成功之后（supervisor
                // 还没探到新一代）、恢复流程请求 reconcile 之后，这两个窗口退出同样会截断 reconcile ⇒ 下次冷启动 baseline 不 reconcile
                // ⇒ 白名单容器一直停着。空闲时代价只是一次探测；只有 reconcile 在途时才会等。
                //
                // 白名单写入链**排在 settle 之前**（R4 F：settle 触发的 reconcile 读的是磁盘上的白名单），且与 settle 共用一个 60 秒总预算——
                // 写入链可能卡在文件系统上，原来那句无上限的 `awaitWrites()` 会把退出永远冻住。
                let handOff = await QuitHandOff.run(
                    budget: quitHandOffLimit,
                    awaitWrites: { await whitelist.awaitWrites() },
                    settle: { await supervisor.settleBeforeStop(within: $0) }
                )
                if handOff != .completed {
                    Logger(subsystem: SupervisorLogging.subsystem, category: "runtime-update")
                        .error("quit hand-off ended early: \(String(describing: handOff), privacy: .public) (budget \(quitHandOffLimit.components.seconds, privacy: .public)s)")
                }
            },
            stopSupervisor: { await supervisor.stop() }
        ))
    }

    // MARK: - 运行时更新器装配（Day 22）

    /// 生产环境的更新器依赖。白名单读的是 supervisor 读的那一份（`WhitelistStore`），先排空写入链——
    /// 与 `forceReconcile` 同一条纪律：勾完立刻升级，那次写可能还没落地。
    private static func makeUpdateStore(
        supervisor: Supervisor,
        whitelistStore: WhitelistStore,
        whitelistUI: WhitelistUIStore,
        isPrimaryInstance: Bool
    ) -> RuntimeUpdateStore {
        var commands: any RuntimeCommanding = RuntimeCommands()
        #if DEBUG
        let pretend = launchArgument("COFUpdatePretendInstalledVersion").flatMap(RuntimeVersion.init(parsing:))
        let failRunningList = launchArgument("COFUpdateFailRunningList") == "YES"
        if pretend != nil || failRunningList {
            commands = PretendingRuntimeCommands(base: commands, pretend: pretend, failRunningList: failRunningList)
        }
        #endif

        let environment = RuntimeUpdateEnvironment(
            commands: commands,
            managedContainerIDs: {
                await whitelistUI.awaitWrites()
                return await whitelistStore.enabledIDs()
            },
            requestManagedReconcile: {
                await whitelistUI.awaitWrites()
                // 先探一次再下达（R5）：更新器刚起回运行时，supervisor 可能还停在 runtimeDown，直接 forceReconcile 会被拒。
                await supervisor.reconcileManagedNow()
            },
            authorizationPrompt: { from, to in RuntimeUpdatePresentation.authorizationPrompt(from: from, to: to) }
        )
        return RuntimeUpdateStore(
            environment: environment, preferences: UserDefaultsUpdatePreferences(), isPrimaryInstance: isPrimaryInstance
        )
    }

    /// 退出前交接的总预算（R2 F / R4 F：白名单写入链 + supervisor 交接共用）。白名单 reconcile 通常几秒；探测 / 启动 / 写盘挂死时靠它放手。
    private static let quitHandOffLimit: Duration = .seconds(60)

    /// 首检延迟。DEBUG 下可用启动参数 `-COFUpdateInitialDelay <秒>` 缩短（T13 真机验收用）。
    private static var updateInitialDelay: TimeInterval {
        #if DEBUG
        if let raw = launchArgument("COFUpdateInitialDelay"), let seconds = TimeInterval(raw) {
            return seconds
        }
        #endif
        return RuntimeUpdateScheduler.initialDelay
    }

    #if DEBUG
    /// DEBUG 测试缝只认**这一次启动的命令行参数**（argument domain），不读持久域（安全评审 INFO）：
    /// `UserDefaults.standard` 会把一次 `defaults write` 留下的值也读出来，于是之后每次 DEBUG 启动都悄悄「假装」旧版本。
    /// 实测（本 session）：持久域写入后 `standard.string(forKey:)` 读得到、argument domain 读不到；带 `-Key value` 启动两者都读得到。
    private static func launchArgument(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }
    #endif
}
