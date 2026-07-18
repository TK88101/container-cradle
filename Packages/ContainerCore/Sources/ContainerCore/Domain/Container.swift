/// 一个容器。domain 侧的**唯一**容器表示——上游的 `ContainerSnapshot` 到此为止（D1）。
///
/// ## 为什么没有 `startedAt`
///
/// 上游 `ContainerSnapshot` 有 `startedDate`，这里刻意不映射：没有消费者。
/// M0 的菜单不显示 uptime；supervisor 的边沿检测靠 `RuntimeGeneration = (pid, startTime)` 令牌
/// （D3），不看容器的启动时间。
///
/// 而带上它有实打实的代价：`FakeContainerRuntimeClient.start()` 就得往里塞一个时间戳，
/// 于是要么调 `Date()`（测试变成不确定的），要么注入一个 `Clock`（为一个没人读的字段
/// 引入一整套时钟抽象）。真需要显示 uptime 那天再加，那时它会有测试压力去做对。
///
/// ## `environment` 是 D2 的落点
///
/// 值类型是 `EnvironmentVariable`（其 `value` 是 `SecretString`），不是 `[String: String]`。
/// 所以「把整个 `Container` 插进日志」这个最顺手的写法，产出的也是 `<redacted>`——
/// 不是因为谁记得打码，而是因为明文根本走不出来。`DomainTests` 钉死了这条。
public struct Container: Sendable, Equatable, Identifiable {

    public let id: ContainerID
    public let image: ImageRef
    public let state: ContainerState
    public let environment: [EnvironmentVariable]

    public init(
        id: ContainerID,
        image: ImageRef,
        state: ContainerState,
        environment: [EnvironmentVariable]
    ) {
        self.id = id
        self.image = image
        self.state = state
        self.environment = environment
    }
}
