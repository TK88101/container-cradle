import Foundation

/// 镜像引用，形如 `docker.io/library/nginx:latest`。
///
/// **刻意不解析** registry / repository / tag / digest：现在没有任何消费者需要拆开它
/// （M0 的菜单只展示，M5 才做 image 管理）。而 OCI 引用的解析规则有一堆边角
/// （省略的 registry、`@sha256:` digest、端口号里的 `:` 与 tag 的 `:` 撞车），
/// 提前写就是提前写 bug——而且是没有测试压力去写对的 bug。
///
/// 真需要拆的那天，拆法会由那时的需求决定，不由今天的想象决定。
public struct ImageRef: Hashable, Sendable, CustomStringConvertible {

    public let rawValue: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}
