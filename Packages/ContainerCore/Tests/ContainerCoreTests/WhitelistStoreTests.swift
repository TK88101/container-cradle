import Foundation
import Testing

@testable import ContainerCore

/// 白名单是**配置资产**（PLAN：要能查看、手改、备份、进 git），不是缓存。
///
/// 所以下面每一条测试都在守同一件事：**用户写下的东西不会被我们弄丢**——
/// 文件坏了不许崩、不许静默清空、不许覆盖；写到一半断电不许留下半个文件。
@Suite("WhitelistStore")
struct WhitelistStoreTests {

    /// 每个 `@Test` 都会新建一次 suite 实例，所以每个测试拿到独立目录，互不污染。
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whitelist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var url: URL { directory.appendingPathComponent("supervisor.json") }
    private var corruptURL: URL { url.appendingPathExtension("corrupt") }

    private func store() -> WhitelistStore { WhitelistStore(url: url) }

    private func write(_ raw: String) throws {
        try raw.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 空与往返

    /// 首次运行时文件当然不存在。**这不是错误**——
    /// 判成错误的话，一个刚装好 App 的用户会在菜单栏看到一条报错。
    @Test("文件不存在 → 空白名单，不是错误")
    func missingFileIsEmpty() async {
        #expect(await store().entries().isEmpty)
    }

    @Test("写入后读回来，内容相同")
    func roundTrip() async throws {
        let entries = [
            WhitelistEntry(id: ContainerID("open-connector")!),
            WhitelistEntry(id: ContainerID("postgres")!, enabled: false),
        ]

        try await store().replace(with: entries)

        // 新开一个 store，强制走真实的读盘路径（不吃上一个实例的缓存）。
        #expect(await store().entries() == entries)
    }

    /// 它是**给人改的**文件。ID 必须是裸字符串，不是 `{"rawValue": …}` 那种包装。
    @Test("落盘格式对人友好：id 是裸字符串，带 version")
    func onDiskFormatIsHumanEditable() async throws {
        try await store().replace(with: [WhitelistEntry(id: ContainerID("open-connector")!)])

        let json = try read()

        #expect(json.contains("\"version\""))
        #expect(json.contains("\"open-connector\""))
        #expect(!json.contains("rawValue"))
    }

    // MARK: - ★ 损坏降级：绝不崩、绝不静默抹掉

    /// 读到坏文件时的三条纪律，缺一不可：
    /// 1. **不崩**——supervisor 是常驻进程，它崩了核心价值就没了；
    /// 2. **不静默清空**——直接返回空白名单而不留痕，用户的配置就人间蒸发了；
    /// 3. **不覆盖**——坏文件必须先备份出去，之后的写入才允许发生。
    @Test("JSON 损坏 → 降级为空 + 坏文件被备份（内容原样保留）")
    func corruptJSONIsBackedUpNotLost() async throws {
        let garbage = "{ this is not json"
        try write(garbage)

        #expect(await store().entries().isEmpty)
        #expect(try String(contentsOf: corruptURL, encoding: .utf8) == garbage)
    }

    /// 将来的 App 版本可能写 version 2。**老版本读到它必须退让，不能硬解**——
    /// 硬解会把不认识的字段丢掉，然后在下一次写入时把它们**永久删掉**。
    @Test("version 不认识 → 当作损坏（备份 + 空），绝不硬解")
    func unknownVersionIsBackedUp() async throws {
        let future = #"{"version": 99, "entries": []}"#
        try write(future)

        #expect(await store().entries().isEmpty)
        #expect(try String(contentsOf: corruptURL, encoding: .utf8) == future)
    }

    /// ★ 这条验的是 `ContainerID` 的 `Decodable` **真的在校验**。
    ///
    /// 合成的 Decodable 会把 `""` 直接塞进 `rawValue`，解出一个「空 ID」的 `ContainerID`——
    /// 「非法值构造不出来」那条不变式当场作废，而且是从**最不可信的入口**
    /// （用户手写的配置文件）被绕开的。
    @Test("ID 为空串 → 解码失败 → 走损坏降级（校验没被 Codable 绕开）")
    func emptyIDIsRejected() async throws {
        try write(#"{"version": 1, "entries": [{"id": "", "enabled": true}]}"#)

        #expect(await store().entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    // MARK: - 原子写

    /// 写 = 先写 temp、再 rename。进程死在两者之间，**原文件完好无损**。
    /// 直接往目标文件上写（truncate → write）会留下一个半截 JSON，
    /// 下次启动读到它 → 走损坏降级 → 用户的白名单实际上就没了。
    @Test("写入后目录里没有残留的临时文件")
    func writeLeavesNoTempFiles() async throws {
        try await store().replace(with: [WhitelistEntry(id: ContainerID("a")!)])

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["supervisor.json"])
    }

    /// 覆盖写：旧内容必须被完整替换，不能留下上一份的尾巴
    /// （短内容盖长内容时，truncate 没做好就会）。
    @Test("覆盖写：新内容完整替换旧内容")
    func overwriteReplacesEntirely() async throws {
        try await store().replace(with: [
            WhitelistEntry(id: ContainerID("aaaaaaaaaaaaaaaaaaaa")!),
            WhitelistEntry(id: ContainerID("bbbbbbbbbbbbbbbbbbbb")!),
        ])
        try await store().replace(with: [WhitelistEntry(id: ContainerID("c")!)])

        #expect(await store().entries() == [WhitelistEntry(id: ContainerID("c")!)])
        #expect(try !read().contains("aaaa"))
    }

    /// 降级之后**用户仍然能把白名单重新配好**——坏文件被移走了，写入路径是通的。
    /// （若坏文件还占着位置、或 store 记住了「我坏了」这个状态，用户就只能去 Finder 里手动删。）
    @Test("损坏降级之后仍可正常写入")
    func canWriteAfterCorruption() async throws {
        try write("{ broken")
        let store = store()

        #expect(await store.entries().isEmpty)

        let entries = [WhitelistEntry(id: ContainerID("a")!)]
        try await store.replace(with: entries)

        #expect(await self.store().entries() == entries)
    }

    // MARK: - 缓存

    /// 用户在 Finder 里手改了 `supervisor.json` —— 这是**预期用法**
    /// （PLAN：它是配置资产，要能查看、手改、备份）。
    /// 没有 `reload()`，进程要重启才认得那次修改。
    @Test("reload 之后能读到外部对文件的修改")
    func reloadPicksUpExternalEdits() async throws {
        let store = store()
        try await store.replace(with: [WhitelistEntry(id: ContainerID("a")!)])

        // 用户手动编辑了文件。
        try write(#"{"version": 1, "entries": [{"id": "manual", "enabled": true}]}"#)

        // 还在吃缓存。
        #expect(await store.entries() == [WhitelistEntry(id: ContainerID("a")!)])

        await store.reload()

        #expect(await store.entries() == [WhitelistEntry(id: ContainerID("manual")!)])
    }

    /// 生产路径必须指向 Application Support。指错地方，用户的白名单会被写进
    /// 一个他永远找不到的目录——而「你可以手改这个文件」当场变成空话。
    @Test("默认位置：~/Library/Application Support/CradleOfFilth/supervisor.json")
    func defaultLocation() {
        let path = WhitelistStore.default().url.path

        #expect(path.hasSuffix("/Application Support/CradleOfFilth/supervisor.json"))
    }
}
