import Testing

@testable import ContainerCore

/// Domain 最小集：`ContainerID` / `ImageRef` / `ContainerState` / `Container`。
///
/// 这四个类型是 D1 的枢轴：`ContainerRuntimeClient` 的签名里**只准出现它们**。
/// 上游的 `ContainerSnapshot` / `RuntimeStatus` 一个字都不许漏进来——
/// 那是 M1 的 mapper 的活，爆炸半径锁死在那 4 个文件里。
@Suite("Domain：标识符必须在边界处校验")
struct DomainTests {

    // MARK: - ContainerID

    /// ID 来自三个**外部**来源：上游 snapshot、用户写的白名单配置、UI 输入。
    /// 三个都不可信 → 校验放在构造处，让「非法 ID」成为一个构造不出来的值。
    @Test("空白 ID 构造不出来", arguments: ["", " ", "\t", "\n", "   "])
    func rejectsBlankID(raw: String) {
        #expect(ContainerID(raw) == nil)
    }

    @Test("合法 ID 原样保留")
    func preservesID() throws {
        let id = try #require(ContainerID("open-connector"))
        #expect(id.rawValue == "open-connector")
    }

    /// 白名单是 `Set<ContainerID>`，supervisor 每轮轮询都要拿它查表 → 必须能当 key。
    @Test("ID 可作字典 key")
    func idIsHashable() throws {
        let a = try #require(ContainerID("db"))
        let b = try #require(ContainerID("db"))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }

    // MARK: - ImageRef

    @Test("空白 image 引用构造不出来", arguments: ["", "  "])
    func rejectsBlankImage(raw: String) {
        #expect(ImageRef(raw) == nil)
    }

    @Test("image 引用原样保留（不解析 registry/tag——还没有消费者）")
    func preservesImageReference() throws {
        let image = try #require(ImageRef("docker.io/library/nginx:latest"))
        #expect(image.rawValue == "docker.io/library/nginx:latest")
    }

    // MARK: - ContainerState

    /// 刻意与上游 `RuntimeStatus` 的四个 case 一一对应（已核实源码）。
    /// 但它是 **domain 拥有的** enum：上游哪天加个 `paused`，改的是 mapper，不是这里。
    @Test("状态集合就是这四个")
    func stateHasExactlyFourCases() {
        #expect(ContainerState.allCases.count == 4)
        #expect(Set(ContainerState.allCases) == [.unknown, .stopped, .running, .stopping])
    }

    // MARK: - Container

    @Test("容器带得住 env（D2 的落点）")
    func containerCarriesEnvironment() throws {
        let secret = try #require(EnvironmentVariable(parsing: "OOMOL_CONNECT_ENCRYPTION_KEY=hunter2"))
        let container = Container(
            id: try #require(ContainerID("open-connector")),
            image: try #require(ImageRef("oomol/connector:1.0")),
            state: .running,
            environment: [secret]
        )

        #expect(container.environment.count == 1)
        #expect(container.environment[0].key == "OOMOL_CONNECT_ENCRYPTION_KEY")
    }

    /// D2 的类型级保障必须**穿透聚合类型**：把 `Container` 整个 log 出去
    /// （`"\(container)"` 是最顺手的写法）也不能漏明文。
    /// `SecretString` 挡住了自己的 `description`，但只有真的插值一遍才知道
    /// 合成的 `Container` 描述有没有绕过去。
    @Test("整个容器插进字符串也不漏明文")
    func interpolatingWholeContainerRedactsSecrets() throws {
        let container = Container(
            id: try #require(ContainerID("open-connector")),
            image: try #require(ImageRef("oomol/connector:1.0")),
            state: .running,
            environment: [try #require(EnvironmentVariable(parsing: "KEY=hunter2"))]
        )

        let rendered = "\(container)" + String(describing: container) + String(reflecting: container)

        #expect(!rendered.contains("hunter2"))
        #expect(rendered.contains("open-connector"))  // 非密数据照常可见，否则没法调试
    }
}
