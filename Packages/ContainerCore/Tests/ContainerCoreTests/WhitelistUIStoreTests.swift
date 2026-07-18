import Foundation
import Testing

@testable import ContainerCore

/// 白名单的**写入侧**。读侧（`WhitelistStore`）Day 5 已经守住了；这里守的是
/// 「用户在菜单里点一下勾选框」到「文件里那一行」之间的路。
///
/// 两条不变式：
/// 1. **取消受管 ≠ 删掉条目**（`WhitelistEntry.enabled` 的文档：调试时临时关掉，配置不能丢）；
/// 2. **连续点击不能丢写**——两次点击各自 `await` 一次落盘，而 actor **不保证 FIFO**，
///    后发起的那次可能先落盘，于是文件里留下的是**旧快照**。UI 上勾着，文件里没有。
@Suite("WhitelistUIStore")
@MainActor
struct WhitelistUIStoreTests {

    private func id(_ raw: String) -> ContainerID { ContainerID(raw)! }

    @Test("载入：只有 enabled 的条目算受管")
    func loadsManagedEntries() async {
        let writer = FakeWhitelistWriter(entries: [
            WhitelistEntry(id: id("a"), enabled: true),
            WhitelistEntry(id: id("b"), enabled: false),
        ])
        let store = WhitelistUIStore(writer: writer)

        await store.load()

        #expect(store.isManaged(id("a")))
        #expect(!store.isManaged(id("b")))
    }

    @Test("勾选一个新容器 → 落盘新增 enabled 条目")
    func managingNewContainerPersists() async {
        let writer = FakeWhitelistWriter(entries: [])
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), true)
        await store.awaitWrites()

        #expect(store.isManaged(id("a")))
        #expect(await writer.saved == [[WhitelistEntry(id: id("a"), enabled: true)]])
    }

    /// ★ 取消受管**不删条目**，只把 `enabled` 翻成 false。
    /// 删掉的话，用户调试完想恢复，得重新把 ID 敲一遍——然后大概率忘了敲。
    @Test("取消受管：条目留着，enabled 翻成 false")
    func unmanagingKeepsEntry() async {
        let writer = FakeWhitelistWriter(entries: [WhitelistEntry(id: id("a"), enabled: true)])
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), false)
        await store.awaitWrites()

        #expect(!store.isManaged(id("a")))
        #expect(await writer.saved.last == [WhitelistEntry(id: id("a"), enabled: false)])
    }

    /// ★ **写入必须串成一条链。** 两次点击若各自并发落盘，落盘顺序不由点击顺序决定——
    /// 最后留在文件里的可能是**第一次点击的快照**，而界面上显示的是第二次的结果。
    /// 下次开机，supervisor 读的是文件，不是界面。
    @Test("连续两次点击：最后落盘的一定是最新快照")
    func consecutiveTogglesLandInOrder() async {
        let writer = FakeWhitelistWriter(entries: [])
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), true)
        store.setManaged(id("b"), true)
        await store.awaitWrites()

        let last = await writer.saved.last
        #expect(
            last == [
                WhitelistEntry(id: id("a"), enabled: true),
                WhitelistEntry(id: id("b"), enabled: true),
            ]
        )
        #expect(store.isManaged(id("a")) && store.isManaged(id("b")))
    }

    /// ★ **手改 JSON 必须真的生效**（codex review 抓到的）。
    ///
    /// 菜单里那句「显示白名单文件」和 `WhitelistStore` 的文档都在承诺「用户可以手改」。
    /// 而 `WhitelistStore.entries()` 是**带缓存**的——不 `reload()`，手改的内容要到
    /// App 重启才被看见。那句承诺就是空话，而且**没有任何东西会告诉用户它是空话**。
    @Test("再次 load → 重读磁盘，看得见外部手改")
    func loadRereadsDiskAfterExternalEdit() async {
        let writer = FakeWhitelistWriter(entries: [])
        let store = WhitelistUIStore(writer: writer)
        await store.load()
        #expect(!store.isManaged(id("a")))

        // 用户在 Finder 里手改了 supervisor.json。
        await writer.simulateExternalEdit([WhitelistEntry(id: id("a"), enabled: true)])
        await store.load()

        #expect(store.isManaged(id("a")))
    }

    /// ★ **在途的写必须先落地，再重读**。
    ///
    /// 否则 load 从磁盘读回的是「写之前」的内容，而那个写随后照样落盘——
    /// 最终 UI 显示旧的、磁盘是新的。两边都自洽，凑一起是错的。
    /// 闸门必须加在**写**那一侧，否则测不准：不闸的话，那次写往往「碰巧」在 load 读盘前
    /// 就落地了，于是**即使不排空，load 也读得到正确的东西**——测试假绿
    /// （实测：突变掉排空，它照样通过）。
    @Test("load 前先把在途的写排空，不会读回一个已经过时的磁盘")
    func loadDrainsPendingWrites() async {
        let writer = SlowWriteWhitelistWriter(entries: [])
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), true)          // 写卡在盘上，还没落地

        let reloading = Task { await store.load() }
        await writer.waitUntilWriting()
        await writer.releaseWrite()              // 写这才落地

        await reloading.value

        // 排空之后再读，读到的是「写完之后」的磁盘。不排空的话读回空列表，
        // 界面上的勾就没了——而磁盘上那条 enabled 的记录还好端端躺着。
        #expect(store.isManaged(id("a")))
        #expect(await writer.current == [WhitelistEntry(id: id("a"), enabled: true)])
    }

    /// ★ **`load()` 里有 `await`，而 MainActor 在 await 处可重入**——
    /// 用户在这期间点了勾选框，load 恢复后若照样把磁盘内容赋值上去，
    /// **那一下点击就被静默吞掉了**：界面弹回未勾选，用户以为自己没点中。
    ///
    /// 这是本仓库第五次遇到同一个形状（`ContainerListStore` / reducer / `Supervisor.stop`
    /// / 快照乱序）。跨过 await 之后，必须重新证明自己还是最新的那一个。
    /// 用**可闸住的**替身把 load 精确地卡在 `entries()` 里，不靠「但愿它们交错了」撞运气。
    ///
    /// 第一版写成 `Task { await store.load() }` 然后紧跟着 `setManaged`——
    /// 那是**假绿**：MainActor 上新建的 Task 不会立刻开跑，`setManaged` 先同步跑完了，
    /// 那个交错窗口根本没被撞到（突变验证：拿掉令牌，它照样通过）。
    @Test("load 途中用户点了勾 → 用户的点击胜出，不被磁盘内容盖掉")
    func userToggleDuringLoadWins() async {
        let writer = GatedWhitelistWriter(entries: [])
        let store = WhitelistUIStore(writer: writer)

        let loading = Task { await store.load() }

        await writer.waitUntilReading()    // load 此刻正卡在 entries() 里
        store.setManaged(id("a"), true)    // 就在这个窗口里，用户点了一下
        await writer.release()             // 磁盘（空的）这才返回

        await loading.value
        await store.awaitWrites()

        // 用户的点击必须胜出。被磁盘那份空内容盖掉的话，勾选框会自己弹回去，
        // 而他以为自己没点中——然后再点一次，如此循环。
        #expect(store.isManaged(id("a")))
        #expect(await writer.current == [WhitelistEntry(id: id("a"), enabled: true)])
    }

    /// ★★ **排空在途写入的那段等待，本身也是一个可重入窗口**（codex review 第二轮抓到的）。
    ///
    /// `awaitWrites()` 等的是**调用那一刻**的写入链。用户在这段等待里又点一下，
    /// 新的写会挂到链尾——而 `awaitWrites()` 不等它。若令牌是**排空之后**才取的，
    /// 取到的就已经是「用户点击之后」的值：校验必然通过，磁盘上的旧内容照样把新点击盖掉。
    ///
    /// 令牌必须在**第一个 `await` 之前**取。「跨过 await 之后重新证明自己」这句话里的
    /// 「自己」，起点得是**进门那一刻**，不能是中途某个看起来安静的时刻。
    @Test("排空在途写入期间用户又点了勾 → 那一下点击照样胜出")
    func toggleDuringDrainWins() async {
        let writer = SlowWriteWhitelistWriter(entries: [])
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), true)          // 第一次写：卡在盘上

        let reloading = Task { await store.load() }
        await writer.waitUntilWriting()          // load 此刻正卡在 awaitWrites() 里

        store.setManaged(id("b"), true)          // ★ 就在这段等待里，用户又点了一下

        // 只放行第一次写。第二次写仍被闸住 → load 读盘时磁盘上还只有 a，
        // 「令牌取晚了」这个 bug 于是**必然**暴露，而不是碰运气。
        await writer.releaseWrite()
        await reloading.value

        await writer.releaseAll()
        await store.awaitWrites()

        // 两下点击都必须活着。第二下被磁盘旧内容盖掉的话，勾选框自己弹回去，
        // 而用户完全不知道 b 没有被纳入白名单——直到某天发现它没被拉起来。
        #expect(store.isManaged(id("a")))
        #expect(store.isManaged(id("b")))
    }

    /// ★★★ **洗空白名单必须在结构上不可能，而不是靠调用顺序。**
    ///
    /// 落盘若写的是「内存里那份 `entries`」，那么任何一次**在首次 `load()` 完成之前**
    /// 发生的 `setManaged`，都会拿一个**空列表**当作全量快照写下去——
    /// 用户磁盘上原有的白名单条目**被整份洗掉**。而白名单是配置资产，不是缓存
    /// （`WhitelistStore` 的文档），洗掉就是不可挽回的丢失。
    ///
    /// 第一版的防线是「view 的 `.task` 里先 load 再 refresh」——那是**靠记得**。
    /// 以后任何一次顺序改动、任何一条新的调用路径，都会重新打开这个洞，
    /// 而编译器和测试都不会吭一声。
    ///
    /// 真正的防线：**落盘前先读磁盘、合并、再写**。于是不管内存里那份有多空，
    /// 磁盘上的条目都不可能被一次勾选抹掉。
    @Test("首次 load 之前就勾选 → 磁盘上原有的条目不许被洗掉")
    func toggleBeforeLoadDoesNotWipeExistingEntries() async {
        // 磁盘上本来就有两条（用户之前配好的）。
        let writer = FakeWhitelistWriter(entries: [
            WhitelistEntry(id: id("old-one"), enabled: true),
            WhitelistEntry(id: id("old-two"), enabled: false),
        ])
        let store = WhitelistUIStore(writer: writer)

        // **没有 load。** 直接勾了一个新的。
        store.setManaged(id("fresh"), true)
        await store.awaitWrites()

        let onDisk = await writer.current

        #expect(onDisk.contains(WhitelistEntry(id: id("old-one"), enabled: true)))
        #expect(onDisk.contains(WhitelistEntry(id: id("old-two"), enabled: false)))
        #expect(onDisk.contains(WhitelistEntry(id: id("fresh"), enabled: true)))
    }

    /// 落盘失败（磁盘满 / 权限）**必须能被看见**。静默吞掉的话，用户以为配置好了，
    /// 而下次开机 supervisor 什么都不会拉——本 App 的核心价值静默归零。
    @Test("落盘失败 → saveError 被记下")
    func surfacesSaveFailure() async {
        let writer = FakeWhitelistWriter(entries: [], failing: true)
        let store = WhitelistUIStore(writer: writer)
        await store.load()

        store.setManaged(id("a"), true)
        await store.awaitWrites()

        #expect(store.saveError != nil)
    }
}

// MARK: - 替身

/// 记下每一次落盘的**完整快照**（不是只留最后一次）——顺序本身就是被测对象。
/// ★ **这个替身必须带缓存**，因为真的那个（`WhitelistStore`）带缓存。
///
/// 第一版没带——于是「再次 load 看得见手改」那条测试**不调 `reload()` 也会绿**：
/// 替身每次都从「磁盘」读，缓存这个维度被压成了常数，而 codex 抓到的 bug
/// **恰恰就活在那个维度上**。
///
/// CLAUDE.md 记着这一条：测试装置若把某个维度压成常数，那个维度上的 bug 就是隐形的。
/// 先问：我固定住了什么？
actor FakeWhitelistWriter: WhitelistWriting {

    /// 「磁盘上现在是什么」。
    private(set) var current: [WhitelistEntry]

    /// 「上次读盘读到的是什么」——`reload()` 之前，`entries()` 只认它。
    private var cached: [WhitelistEntry]?

    private let failing: Bool
    private(set) var saved: [[WhitelistEntry]] = []

    init(entries: [WhitelistEntry], failing: Bool = false) {
        self.current = entries
        self.failing = failing
    }

    func entries() async -> [WhitelistEntry] {
        if let cached { return cached }

        cached = current
        return current
    }

    func replace(with entries: [WhitelistEntry]) async throws {
        if failing {
            throw CocoaError(.fileWriteNoPermission)
        }

        current = entries
        cached = entries
        saved.append(entries)
    }

    func reload() async {
        cached = nil
    }

    /// 用户在 Finder 里手改了那个 JSON。**只动「磁盘」，不动缓存**——
    /// 这正是真实情形：App 的缓存并不知道文件被改了。
    func simulateExternalEdit(_ entries: [WhitelistEntry]) {
        current = entries
    }
}

/// 能把 `replace()` **闸住**的 writer——用来把「写还在途」这个状态**钉死**。
///
/// 不闸的话，那次写往往在 load 读盘之前就碰巧落地了，于是「排空在途写入」这条防线
/// 即使被拿掉，测试也照样绿（实测撞到过）。
actor SlowWriteWhitelistWriter: WhitelistWriting {

    private(set) var current: [WhitelistEntry]
    private var cached: [WhitelistEntry]?

    private var writeCount = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(entries: [WhitelistEntry]) {
        self.current = entries
    }

    func entries() async -> [WhitelistEntry] {
        if let cached { return cached }

        cached = current
        return current
    }

    /// **每一次写都闸**，不是「放行一次之后就一路畅通」。
    ///
    /// 放行一次就全开的话，排在链尾的第二次写会立刻跑完，于是 load 读盘时磁盘上
    /// 「碰巧」已经是最新内容了——测试又变成跟调度器赛跑（实测：带 bug 也全绿）。
    func replace(with entries: [WhitelistEntry]) async throws {
        writeCount += 1

        entered?.resume()
        entered = nil

        if !isReleased {
            await withCheckedContinuation { gate = $0 }
        }

        current = entries
        cached = entries
    }

    func reload() async {
        cached = nil
    }

    func waitUntilWriting() async {
        guard writeCount == 0 else { return }

        await withCheckedContinuation { entered = $0 }
    }

    /// 只放行**当前**卡住的那一次写；后面的写照样会被闸住。
    func releaseWrite() {
        gate?.resume()
        gate = nil
    }

    /// 全开（测试收尾用，否则挂在链尾的写永远等不到，`awaitWrites()` 会一直挂着）。
    func releaseAll() {
        isReleased = true
        gate?.resume()
        gate = nil
    }
}

/// 能把 `entries()` **闸住**的 writer——用来把 `load()` 精确地停在它的 `await` 里。
///
/// 不这么做，「load 途中用户点了勾」这条测试就是在跟调度器赛跑：
/// MainActor 上新建的 Task 不会立刻开跑，于是那个窗口根本没被撞到，测试变成假绿。
actor GatedWhitelistWriter: WhitelistWriting {

    private(set) var current: [WhitelistEntry]

    private var readCount = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(entries: [WhitelistEntry]) {
        self.current = entries
    }

    /// **快照在进门那一刻就取**，返回被推迟。
    ///
    /// 这不是为了方便：它就是真实语义（读盘已经发生了，只是结果还没送到）。
    /// 若改成「放行时才读 `current`」，那期间落盘的那次写就会把内容补上去——
    /// 于是**即使没有令牌，load 也会「碰巧」读回正确的东西**，测试变成假绿
    /// （实测撞到过：突变掉令牌，它照样通过）。
    func entries() async -> [WhitelistEntry] {
        readCount += 1

        let snapshot = current

        entered?.resume()
        entered = nil

        if !isReleased {
            await withCheckedContinuation { gate = $0 }
        }

        return snapshot
    }

    func replace(with entries: [WhitelistEntry]) async throws {
        current = entries
    }

    func reload() async {}

    /// 等到 `entries()` 真的进来了。
    func waitUntilReading() async {
        guard readCount == 0 else { return }

        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }
}
