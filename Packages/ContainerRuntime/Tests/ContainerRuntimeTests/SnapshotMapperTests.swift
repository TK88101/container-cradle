import ContainerCore
import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntime

@Suite("SnapshotMapper：上游 → domain，含脱敏")
struct SnapshotMapperTests {

    // MARK: - golden fixture（R1 的第二道闸）

    @Test("真机录的 snapshot 能 decode 并映射成 domain")
    func mapsRecordedSnapshot() throws {
        let container = try SnapshotMapper.map(Fixtures.openConnector())

        #expect(container.id.rawValue == "open-connector")
        #expect(container.image.rawValue == "ghcr.io/oomol-lab/open-connector:latest")
        #expect(container.state == .running)
    }

    /// 上游的 4 个 `RuntimeStatus` 全部有对应。
    ///
    /// **穷尽 switch，不用 rawValue 转换**——后者在上游改名时照样编译，
    /// 只是运行时开始返回 `nil`（一个状态悄悄消失）。这条测试连同那个 switch 一起，
    /// 让「上游改 case」变成构建期事故而不是运行期事故。
    @Test(
        "四个上游状态一一对应",
        arguments: zip(
            [RuntimeStatus.unknown, .stopped, .running, .stopping],
            [ContainerState.unknown, .stopped, .running, .stopping]
        )
    )
    func mapsEveryStatus(upstream: RuntimeStatus, expected: ContainerState) {
        #expect(SnapshotMapper.state(from: upstream) == expected)
    }

    // MARK: - ★ D2：脱敏

    /// **R2 的可执行证明。** fixture 里 `OOMOL_CONNECT_ENCRYPTION_KEY` 的值是合成的
    /// `FAKE_AAA…`——但对 mapper 而言它跟真密钥没有区别。
    ///
    /// 断言的是：把整个 `Container` 编码出去，**明文不在里面**。
    /// 这不是「记得打码」，是明文根本走不出 `SecretString`。
    @Test("env 的值全部变成 SecretString：编码整个 Container 也拿不到明文")
    func environmentValuesAreRedacted() throws {
        let snapshot = try Fixtures.openConnector()
        let container = try SnapshotMapper.map(snapshot)

        // 从 fixture 里取出「明文」（这里是合成值，但走的是同一条路）
        let plaintexts = snapshot.configuration.initProcess.environment
            .compactMap { entry -> String? in
                guard let separator = entry.firstIndex(of: "=") else { return nil }
                let value = String(entry[entry.index(after: separator)...])
                return value.count >= 8 ? value : nil          // 短值（如 "3000"）会误命中，跳过
            }
        #expect(!plaintexts.isEmpty, "fixture 里应当有可辨识的长值，否则这条测试什么都没测")

        // ① JSON 编码。`Container` 本身刻意**不**遵从 `Encodable`（没有消费者——
        //    而一个没人读的 conformance 会躲开所有测试压力，然后在真要用它的那天已经漂了）。
        //    真实存在的编码面是 `[EnvironmentVariable]`，密钥就装在这里。
        let json = try #require(
            String(data: JSONEncoder().encode(container.environment), encoding: .utf8)
        )

        // ② `dump` —— 走 Mirror，**绕过 `description`**。这是最隐蔽的一条渠道
        //    （`SecretString` 的 `CustomReflectable` 就是为它写的）。
        var dumped = ""
        dump(container, to: &dumped)

        // ③ 插值整个 Container——最顺手、因而最危险的写法。
        let interpolated = "\(container)"

        for channel in [json, dumped, interpolated] {
            for plaintext in plaintexts {
                #expect(
                    !channel.contains(plaintext),
                    "明文泄漏：\(String(plaintext.prefix(4)))… 出现在了某条输出通道里"
                )
            }
        }

        // 密钥的 **key 名**必须还在（UI 要显示它），只是值被打码了。
        #expect(json.contains("OOMOL_CONNECT_ENCRYPTION_KEY"))
        #expect(json.contains("<redacted>"))
    }

    // MARK: - env 解析的两个边角

    /// 值里含 `=` 的 base64 密钥：**必须按首个 `=` 切分**。
    /// 按最后一个切会得到被截断的密钥——而且错得无声无息。
    @Test("含 = 的 base64 值不被截断")
    func splitsOnFirstEqualsOnly() throws {
        let container = try SnapshotMapper.map(Fixtures.openConnector())
        let base64 = try #require(container.environment.first { $0.key == "BASE64_SECRET" })

        #expect(base64.value.reveal() == "YWJjZGVmZ2hpamtsbW5vcA==")
    }

    /// 畸形条目（没有 `=`）**丢弃，不崩**。上游无 schema 承诺（R1）。
    ///
    /// 丢一条 env 与「映射失败要整体炸」不矛盾：它不会让容器从列表里消失，
    /// supervisor 照常拉它。
    @Test("没有 = 的条目被丢弃，不崩")
    func dropsMalformedEntries() throws {
        let container = try SnapshotMapper.map(Fixtures.openConnector())

        #expect(!container.environment.contains { $0.key == "MALFORMED_NO_EQUALS" })
        #expect(container.environment.contains { $0.key == "PATH" })   // 好的条目照常在
    }

    // MARK: - 失败关闭

    /// 映射不出来 → **抛**，不返回一个「少了一个容器」的列表。
    ///
    /// 静默跳过是本 App 最坏的失败模式：那个容器从列表里消失，supervisor 不再拉它，
    /// 而一切看起来正常。
    @Test("空 image reference → 抛，不静默跳过")
    func throwsOnUnmappableImage() throws {
        var snapshot = try Fixtures.openConnector()
        snapshot.configuration.image = ImageDescription(
            reference: "   ",                                  // 裁完是空 → ImageRef 造不出来
            descriptor: snapshot.configuration.image.descriptor
        )

        #expect(throws: SnapshotMapper.MappingError.self) {
            try SnapshotMapper.map(snapshot)
        }
    }
}
