import Testing

@testable import ContainerCore

/// T2a（Day 16）：`ContainerCloneTemplate` + `MountSummary` 预填域类型（§3.2）。
///
/// clone 预填**纯 domain**：app 不碰上游 `configuration`（codex #1）。模板携带 image（只读继承）、
/// env（每项 `SecretString`、**不 reveal**——D2）、挂载摘要计数（volume/bind/tmpfs）。
/// 「env 保持 SecretString、无 reveal」是本任务的核心守卫。
@Suite("ContainerCloneTemplate 预填")
struct ContainerCloneTemplateTests {

    static let secretValue = "sk-Ab3dEf6hIj9lMn2pQr5tUv8xYz1cDe4fGh7jKl0mNo="

    @Test("image 原样带过")
    func imagePassedThrough() throws {
        let image = try #require(ImageRef("nginx:1.27"))
        let template = ContainerCloneTemplate(
            image: image,
            environment: [],
            mountSummary: MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0)
        )
        #expect(template.image.rawValue == "nginx:1.27")
    }

    /// D2 核心：预填模板持有 env 明文的 `SecretString`，插值/描述恒 `<redacted>`，
    /// 构造模板的过程里不发生 reveal（明文只在 T4 的 create 序列化助手里现身）。
    @Test("env 保持 SecretString，预填不 reveal")
    func envStaysConcealed() throws {
        let image = try #require(ImageRef("nginx"))
        let template = ContainerCloneTemplate(
            image: image,
            environment: [
                EnvironmentVariable(key: "TOKEN", value: SecretString(Self.secretValue)),
                EnvironmentVariable(key: "PATH", value: SecretString("/usr/bin")),
            ],
            mountSummary: MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0)
        )

        #expect(template.environment.count == 2)
        #expect(template.environment[0].key == "TOKEN")
        #expect("\(template.environment[0].value)" == "<redacted>")

        // 整个模板的 env 明文不出现在任何描述里。
        #expect(!"\(template.environment)".contains(Self.secretValue))
    }

    @Test("挂载摘要计数分别保留")
    func mountSummaryCounts() {
        let summary = MountSummary(volumeCount: 2, bindCount: 1, tmpfsCount: 3)
        #expect(summary.volumeCount == 2)
        #expect(summary.bindCount == 1)
        #expect(summary.tmpfsCount == 3)
        #expect(summary.total == 6)
    }

    @Test("空挂载摘要 total 为 0")
    func emptyMountSummaryTotal() {
        #expect(MountSummary(volumeCount: 0, bindCount: 0, tmpfsCount: 0).total == 0)
    }
}
