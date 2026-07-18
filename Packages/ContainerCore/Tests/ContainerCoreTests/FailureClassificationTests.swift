import Testing

@testable import ContainerCore

/// **R13 的落地点。** 这张映射表把「运行时抛了什么错」翻译成「supervisor 该怎么反应」。
///
/// 它错一格，Day 4 整套熔断/退避就白做了——而且**编译绿、测试绿、看不出任何异常**：
/// supervisor 会安静地在错误的时刻放弃，或者安静地无限打铁。
@Suite("RuntimeError → FailureKind")
struct FailureClassificationTests {

    /// ★ **这一格是整个 App 的生死线**（CLAUDE.md D4）。
    ///
    /// mount 源路径没就绪 = Mac 重启后外置盘/网络卷还没挂上，要几十秒到几分钟。
    /// 判成 `.transient` 的话它会计入熔断，而退避 1→2→4→8→16 秒意味着
    /// **五次失败只花 31 秒** → supervisor 在 31 秒后熔断放弃，
    /// 正好死在它唯一该活着的那一刻。
    @Test("mount 源不可用 → environmentNotReady（永不计入熔断）")
    func mountSourceIsEnvironmental() {
        #expect(FailureKind(from: .mountSourceUnavailable(path: "/Volumes/data")) == .environmentNotReady)
    }

    /// 运行时自己死了**不是容器 crashloop 的证据**。拿它去推熔断计数，
    /// 等于「apiserver 抖几下，supervisor 就永久放弃」——恰好是它最该坚持的时刻。
    ///
    /// 而且这条失败债本来就活不长：probe 很快会把状态收敛到 `.runtimeDown`，
    /// reducer 在那里把整串 streak 丢掉。
    @Test("运行时不可用 → environmentNotReady（不是容器的错）")
    func runtimeUnavailableIsEnvironmental() {
        #expect(FailureKind(from: .runtimeUnavailable) == .environmentNotReady)
    }

    /// 白名单里的 ID 拼错了，或者容器被 `container delete` 删了。**重试一万次也没用。**
    /// 归进可重试档，日志会被刷满，真正的问题埋在噪音里。
    @Test("容器不存在 → permanent（不重试、不退避、不熔断）")
    func containerNotFoundIsPermanent() {
        #expect(FailureKind(from: .containerNotFound(ContainerID("ghost")!)) == .permanent)
    }

    /// 这一档才是熔断要防的东西：容器起来就崩、崩了又被拉起。
    @Test("操作失败 → transient（这一档才计入熔断）")
    func operationFailedIsTransient() {
        #expect(FailureKind(from: .operationFailed(reason: "exit status 1")) == .transient)
    }

    /// **只有 `.transient` 推熔断计数。** 这条断言是 R13 的护栏：
    /// 它一旦变红，说明有人把环境失败算进了熔断——supervisor 会在 31 秒后放弃。
    @Test("环境失败绝不落进 transient 档")
    func environmentalFailuresAreNeverTransient() {
        let environmental: [RuntimeError] = [
            .mountSourceUnavailable(path: "/Volumes/data"),
            .runtimeUnavailable,
        ]

        for error in environmental {
            #expect(FailureKind(from: error) != .transient)
        }
    }
}
