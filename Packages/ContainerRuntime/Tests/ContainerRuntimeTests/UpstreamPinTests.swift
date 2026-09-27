import ContainerCore
import Foundation
import Testing

@testable import ContainerRuntime

/// Day 22 T10：`UpstreamPin.version` 与 SPM 的 pin 必须是同一个数（A9 提示「本 App 基于 X 构建并测试」的 X）。
/// 数字写死在两处就一定会漂——升级上游时改了 `Package.swift`、忘了改这里，提示就开始说谎。
@Suite("UpstreamPin：与 Package.swift / Package.resolved 一致")
struct UpstreamPinTests {

    static let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Package.resolved 里 container 的版本 == UpstreamPin.version")
    func matchesResolved() throws {
        let data = try Data(contentsOf: Self.packageDirectory.appendingPathComponent("Package.resolved"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(object["pins"] as? [[String: Any]])
        let container = try #require(pins.first { $0["identity"] as? String == "container" })
        let version = try #require((container["state"] as? [String: Any])?["version"] as? String)
        #expect(RuntimeVersion(parsing: version) == UpstreamPin.version)
    }

    @Test("Package.swift 用 exact: pin 的正是这个版本")
    func matchesManifest() throws {
        let manifest = try String(contentsOf: Self.packageDirectory.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains("url: \"https://github.com/apple/container.git\", exact: \"\(UpstreamPin.version)\""))
    }
}
