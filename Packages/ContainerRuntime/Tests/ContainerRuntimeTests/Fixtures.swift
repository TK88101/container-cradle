import ContainerResource
import Foundation
import Testing

/// Golden fixture 的加载。
///
/// ## fixture 是**录**来的，不是**手写**的
///
/// 手写一份「看起来像 `ContainerSnapshot`」的 JSON，测的只是「我们的 mapper 能读懂我们自己写的
/// JSON」——一句同义反复。它抓不到 R1 要抓的东西（上游改字段 / 改语义）。
///
/// 这份 fixture 是 `Spikes/DependencySpike/Sources/SnapshotRecorder` 从**真 XPC** 拿到
/// `[ContainerSnapshot]` 之后 `JSONEncoder` 编出来的，然后把 env 的**值**换成合成串。
/// 上游改了字段名 → decode 失败 → **红灯**，正是 R1 要的第二道闸。
///
/// ## 为什么不是 `container ls --format json`
///
/// 实测：那个 JSON **不是 `ContainerSnapshot` 的编码**，是 CLI 自己的展示 DTO
/// （`status` 在那边是个对象 `{networks, startedDate, state}`）。拿它当 fixture，
/// 守的是「CLI 的展示格式没变」——**靶子完全错了，而且测试会绿**。
enum Fixtures {

    static func snapshots(_ name: String) throws -> [ContainerSnapshot] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture 找不到：\(name).json"
        )
        return try JSONDecoder().decode([ContainerSnapshot].self, from: Data(contentsOf: url))
    }

    /// 真机录的 `open-connector`：running，11 条 env（含 3 个密钥 key 名），volume mount。
    static func openConnector() throws -> ContainerSnapshot {
        try #require(snapshots("snapshots").first)
    }

    /// ★ R13 的靶子：stopped，带一个 **virtiofs** mount 指向外置盘（另有一个 volume mount 作对照——
    /// 它**不该**被校验）。
    static func needsExternalDisk() throws -> ContainerSnapshot {
        try #require(snapshots("virtiofs-container").first)
    }
}
