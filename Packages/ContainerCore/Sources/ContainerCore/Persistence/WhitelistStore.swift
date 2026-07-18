import Foundation

/// 落盘的白名单文件。
///
/// ```json
/// { "version": 1, "entries": [ { "id": "open-connector", "enabled": true } ] }
/// ```
///
/// **绝不包含任何环境变量 / 密钥**（D2）——它只记「管哪些容器」，不记容器长什么样。
struct WhitelistDocument: Codable, Equatable {

    /// 只认这一个版本。读到别的 → 当作损坏（备份 + 降级），**绝不硬解**：
    /// 硬解会把不认识的字段丢掉，然后在下一次写入时把它们永久删掉。
    static let currentVersion = 1

    let version: Int
    let entries: [WhitelistEntry]
}

/// 白名单的持久化。**这是配置资产，不是缓存**（PLAN：要能查看、手改、备份、进 git）。
///
/// 所以它不用 `UserDefaults`：那东西埋在 plist 里由 `cfprefsd` 缓存，改了不一定立刻生效，
/// 调试地狱。而这个文件用户要能直接打开、看懂、改对。
///
/// ## 三条纪律，一条都不能省
///
/// 1. **不崩。** supervisor 是常驻进程；它崩了，本 App 的核心价值就没了。
///    文件不存在、权限不对、JSON 是乱码——全都得降级，不能抛到调用方脸上。
/// 2. **不静默抹掉。** 读到坏文件就直接返回空白名单的话，用户的配置人间蒸发，
///    而他要到某天发现容器没被拉起时才知道。坏文件**必须先备份出去**。
/// 3. **不留半个文件。** 写 = temp + rename（`Data.write(.atomic)`）。
///    进程死在中间，原文件完好无损；直接 truncate 再写，断电就留下半截 JSON——
///    下次启动读到它 → 走损坏降级 → 白名单实际上就没了。
public actor WhitelistStore: WhitelistProvider {

    /// 配置文件的位置。**public 是因为 UI 需要它**——
    /// 一个「用户可以手改」的配置文件，如果 App 不告诉他在哪，那句话就是空话
    /// （菜单里要有「在 Finder 中显示」）。
    /// `nonisolated`：它是不可变的，读它不需要排队进 actor
    /// （UI 想显示「配置在哪」时，不该为此等一次 actor 跳转）。
    public nonisolated let url: URL

    private var cached: [WhitelistEntry]?

    public init(url: URL) {
        self.url = url
    }

    /// 生产位置：`~/Library/Application Support/CradleOfFilth/supervisor.json`。
    public static func `default`() -> WhitelistStore {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CradleOfFilth", isDirectory: true)

        return WhitelistStore(url: support.appendingPathComponent("supervisor.json"))
    }

    /// **永不抛错、永不崩。** 任何读不出来的情况都退化成空白名单。
    ///
    /// 代价是「白名单为空」这个结果有两种成因（真的空 / 文件坏了）。
    /// 后者不会无声无息：坏文件被备份成 `.corrupt`，那是留给用户和我们的证据。
    public func entries() -> [WhitelistEntry] {
        if let cached { return cached }

        let loaded = load()
        cached = loaded
        return loaded
    }

    /// 整份替换。**先写 temp 再 rename**，所以要么是旧的完整内容、要么是新的完整内容，
    /// 不存在第三种状态。
    public func replace(with entries: [WhitelistEntry]) throws {
        let document = WhitelistDocument(version: WhitelistDocument.currentVersion, entries: entries)

        let encoder = JSONEncoder()
        // 人要读它、手改它、在 git 里 diff 它。紧凑格式在这三件事上都更差。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(to: url, options: .atomic)

        cached = entries
    }

    /// 丢掉缓存，下次 `entries()` 重新读盘（用户在 Finder 里手改了文件之后）。
    public func reload() {
        cached = nil
    }

    // MARK: -

    private func load() -> [WhitelistEntry] {
        guard let data = try? Data(contentsOf: url) else {
            // 文件不存在（首次运行）或读不动。**不是错误**——
            // 判成错误的话，一个刚装好 App 的用户会在菜单栏看到一条报错。
            return []
        }

        guard
            let document = try? JSONDecoder().decode(WhitelistDocument.self, from: data),
            document.version == WhitelistDocument.currentVersion
        else {
            quarantine()
            return []
        }

        return document.entries
    }

    /// 把坏文件挪到 `.corrupt` 去。**挪走而不是留在原地**，两个理由：
    ///
    /// - 用户的配置得留下来（他也许还能从里面把 ID 抄回来）；
    /// - 原位置得腾出来，否则下一次 `replace` 会直接覆盖掉那份唯一的证据。
    ///
    /// 只保留**最近一次**损坏（同名覆盖）：坏文件攒一堆没有额外价值，
    /// 只会在用户的配置目录里堆垃圾。
    private func quarantine() {
        let backup = url.appendingPathExtension("corrupt")

        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
