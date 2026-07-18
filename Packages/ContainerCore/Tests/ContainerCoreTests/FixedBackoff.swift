import Foundation

@testable import ContainerCore

/// 恒返回同一个延迟的退避策略。**Day 3 转移表测试专用。**
///
/// ## 它存在的理由：隔离两个独立命题
///
/// - 「运行时换代时退避计数要清零」是**转移**的性质；
/// - 「第 3 次失败该等 4 秒」是**曲线**的性质。
///
/// 转移测试注入这个恒定策略后，断言里就没有任何数字来自退避曲线——
/// Day 4 把曲线从 `1→2→4` 改成 `2→4→8`，这一批转移测试**一个都不会红**。
/// 反过来，曲线的测试（Day 4）也不需要构造任何状态转移。
///
/// ## 为什么它住 test target，而 `FakeContainerRuntimeClient` 住 `Sources/Testing/`
///
/// 那条先例的理由是 **app target 真的要消费 Fake**（`CradleOfFilthApp.swift` 的
/// composition root 用 `.preview` 渲染菜单），而 app target 没有测试 target——
/// 能被 app 和测试共用的替身只能住进 library。
///
/// `FixedBackoff` 没有这个需求：全仓库只有测试引用它。
/// 先例的理由是「app 要用」，不是「名字里带 Testing」；理由不成立就不该沿用，
/// 否则 library 的 public 面会被一堆没人用的测试替身慢慢撑大。
struct FixedBackoff: BackoffPolicy {

    private let interval: TimeInterval

    init(_ interval: TimeInterval) {
        self.interval = interval
    }

    func delay(forAttempt attempt: Int) -> TimeInterval {
        interval
    }
}
