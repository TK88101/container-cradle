import Foundation
import Observation

/// 白名单的**写入侧**（读侧是 `WhitelistProvider`，生产实现同为 `WhitelistStore`）。
///
/// 抽成 protocol 是为了让 `WhitelistUIStore` 的测试不碰文件系统——而它要守的是并发顺序，
/// 那种测试一旦掺进真实 IO 就会变成薛定谔的绿。
public protocol WhitelistWriting: WhitelistProvider {

    func replace(with entries: [WhitelistEntry]) async throws

    /// 丢掉缓存，下次 `entries()` 重新读盘。
    ///
    /// **它必须在 protocol 上，不能只在 `WhitelistStore` 上**（codex review 抓到的）：
    /// `entries()` 带缓存，不清缓存的话，用户在 Finder 里手改的 JSON 要到 App 重启才生效——
    /// 而菜单里那个「显示白名单文件」按钮和 `WhitelistStore` 的文档都在承诺他可以手改。
    /// 一个不生效的承诺，比没有这个承诺更糟。
    func reload() async
}

extension WhitelistStore: WhitelistWriting {}

/// 菜单里那一排勾选框背后的东西。
///
/// ## 两条它必须守住的东西
///
/// 1. **取消受管 ≠ 删条目。** `enabled` 翻成 false，条目留着
///    （`WhitelistEntry.enabled` 的文档：用户临时停掉一个容器去调试，配置不能跟着蒸发）。
///
/// 2. **写入串成一条链。** 用户连点两下（勾 a、勾 b），两次落盘若各自并发发起，
///    **落盘顺序不由点击顺序决定**（actor 不保证 FIFO）。最后留在磁盘上的可能是第一次的快照：
///    界面上 a、b 都勾着，文件里只有 a——而下次开机 supervisor 读的是文件，不是界面。
///    于是 b 永远不会被拉起，且没有任何东西会告诉用户。
///
///    链式 `await previous?.value` 让每次写都排在前一次之后。代价是连点时多写几次盘
///    （一个 JSON、几百字节），换来的是「最后落盘的一定是最新快照」。
@MainActor
@Observable
public final class WhitelistUIStore {

    /// 完整条目（含 `enabled == false` 的）。UI 只看 `isManaged`，但落盘要写全份。
    public private(set) var entries: [WhitelistEntry] = []

    /// 落盘失败的人话。**必须能被看见**：静默失败意味着用户以为配好了，
    /// 而 supervisor 下次开机什么都不会拉——核心价值静默归零。
    public private(set) var saveError: String?

    private let writer: any WhitelistWriting

    /// 写入链的尾巴。见类型文档第 2 条。
    private var writeChain: Task<Void, Never>?

    /// 用户改过几次。**`load()` 跨过 `await` 之后要靠它证明「没人在我背后动过手」。**
    private var mutations = 0

    public init(writer: any WhitelistWriting) {
        self.writer = writer
    }

    /// 从磁盘重读。菜单每次打开都会调它——因为用户可能刚在 Finder 里手改了那个 JSON。
    ///
    /// ## 三步的顺序不能换
    ///
    /// 1. **先把在途的写排空。** 不排空就 reload，读回的是「写之前」的磁盘内容，
    ///    而那个写随后照样落盘 → **界面显示旧的、磁盘是新的**，两边各自自洽，凑一起是错的。
    /// 2. **再清缓存。** `WhitelistStore.entries()` 带缓存，不清就读不到手改的内容。
    /// 3. **最后验令牌。** 上面两步都是 `await`，而 **MainActor 在 `await` 处可重入**——
    ///    用户完全可能在这期间点了勾选框。不验令牌就会把磁盘内容盖上去，
    ///    **把他那一下点击静默吞掉**（界面弹回未勾选，他以为自己没点中）。
    ///    本仓库第五次遇到这个形状了。
    ///
    /// ## 令牌必须在**第一个 `await` 之前**取（codex review 第二轮抓到的）
    ///
    /// 第一版取在 `awaitWrites()` **之后**——看起来更「贴近使用点」，其实是个洞：
    /// `awaitWrites()` 等的是**调用那一刻**的写入链，用户在这段等待里又点一下，
    /// 新的写会挂到链尾，而它不等那一个。于是排空之后取到的令牌**已经是用户点击之后的值**，
    /// 校验必然通过，磁盘旧内容照样把新点击盖掉。
    ///
    /// 「跨过 await 之后重新证明自己」里的那个「自己」，起点得是**进门那一刻**，
    /// 不能是中途某个看起来安静的时刻——中途的每一刻都可能已经不是原来那个世界了。
    public func load() async {
        let token = mutations

        await awaitWrites()
        await writer.reload()

        let loaded = await writer.entries()

        // 中途用户动过手 → 他的点击是更新的事实，磁盘那份是旧的。**闭嘴退出。**
        // （他那次点击自己会落盘，不需要这里代劳。）
        guard token == mutations else { return }

        entries = loaded
    }

    public func isManaged(_ id: ContainerID) -> Bool {
        entries.contains { $0.id == id && $0.enabled }
    }

    /// 勾 / 取消勾。**先改内存（同步），再排队落盘**——UI 要立刻响应，
    /// 磁盘慢不慢是磁盘的事。
    public func setManaged(_ id: ContainerID, _ managed: Bool) {
        mutations += 1
        entries = Self.updated(entries, id: id, managed: managed)

        persist(id: id, managed: managed)
    }

    /// 等写入链排空。
    ///
    /// 两个调用方，缺一不可：
    /// - `load()`（重读磁盘前，先让在途的写落地，否则读回一份已经过时的磁盘）；
    /// - **App 退出时**（`AppModel.stop`）——勾选是先改内存再排队落盘的，
    ///   用户勾完随手退出，那次写会跟着进程一起消失：界面上勾着，磁盘上没有。
    ///
    /// 顺带它也是测试的确定性等待点。不给这个钩子，测试就只能睡一觉然后但愿它写完了
    /// （CI 上必然间歇性红）。
    public func awaitWrites() async {
        _ = await writeChain?.value
    }

    // MARK: -

    /// 纯函数：**不就地改数组**（全局 §7）。
    static func updated(
        _ entries: [WhitelistEntry],
        id: ContainerID,
        managed: Bool
    ) -> [WhitelistEntry] {
        if entries.contains(where: { $0.id == id }) {
            return entries.map { entry in
                entry.id == id ? WhitelistEntry(id: id, enabled: managed) : entry
            }
        }

        // 不存在的条目：只有「勾上」才需要新建。取消一个不存在的条目 = 无事发生。
        guard managed else { return entries }

        return entries + [WhitelistEntry(id: id, enabled: true)]
    }

    /// ★★ **落盘写的是「磁盘 + 这一次改动」，不是「内存里那份 entries」。**
    ///
    /// 写内存快照的话，任何一次**在首次 `load()` 完成之前**发生的勾选，都会拿一个空列表
    /// 当全量快照写下去——**用户原有的白名单被整份洗掉**。而白名单是配置资产，不是缓存，
    /// 洗掉就是不可挽回的丢失。
    ///
    /// 第一版靠「view 的 `.task` 里先 load 再 refresh」来防这件事。那是**靠记得**：
    /// 以后任何一次顺序改动、任何一条新的调用路径都会重新打开这个洞，
    /// 而编译器和测试都不会吭一声。
    ///
    /// 现在这个形状里，「洗空」**写不出来**——落盘前一定会先看一眼磁盘上有什么。
    /// （代价：每次勾选多一次读。那是个几百字节的本地 JSON，而且读的是 store 的缓存。）
    private func persist(id: ContainerID, managed: Bool) {
        let previous = writeChain
        let token = mutations

        writeChain = Task { [writer] in
            // 排在前一次写之后。**这就是「最后落盘的一定是最新快照」的全部依据**——
            // 也是「读-改-写」在这里安全的依据：链上只有一个写者，不存在两次合并互相覆盖。
            _ = await previous?.value

            do {
                let onDisk = await writer.entries()
                let merged = Self.updated(onDisk, id: id, managed: managed)

                try await writer.replace(with: merged)

                self.saveError = nil

                // 把磁盘的真相同步回界面——但只在用户没继续动手的前提下
                // （他要是又点了一下，那份内存才是最新的事实，别拿磁盘去盖它）。
                if token == self.mutations {
                    self.entries = merged
                }
            } catch {
                self.saveError = error.localizedDescription
            }
        }
    }
}
