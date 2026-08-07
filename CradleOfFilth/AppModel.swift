import ContainerCore
import ContainerRuntime
import Foundation
import Observation

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

    private let supervisor: Supervisor
    private let whitelistStore: WhitelistStore

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

        // 系统通知桥接：store 在 MainActor 上把每份被采纳快照的 notices 投给 notifier
        // （已过 sequence 闸 → 迟到旧快照不会重弹；notifier 再按业务 key 去重）。
        status.onNotices = { [notifier] notices in notifier.handle(notices) }

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
    func start() async {
        // 通知授权：现在请求，用户第一次真被弹之前就把授权拿到手。拒了就静默降级（图标 + 菜单说明）。
        notifier.requestAuthorization()
        await supervisor.start()
        await whitelist.load()
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
        await supervisor.stop()
        await whitelist.awaitWrites()
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
}
