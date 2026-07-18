/// **运行时的失败 → supervisor 的反应。这张表是 R13 的生死线。**
///
/// 它是把 `RuntimeError`（「发生了什么」）翻译成 `FailureKind`（「该怎么办」）的唯一地方。
/// 分开这两个概念不是分层洁癖：
///
/// - `RuntimeError` 会随上游演化（M1 接上真 client 后还会加 case）；
/// - `FailureKind` 是**策略**——退避 / 熔断 / 放弃，只有三种可能，且不该随上游变。
///
/// 混成一个类型，每加一个上游错误就要去 reducer 里改一次熔断逻辑。
///
/// ## 分类**只看 case，绝不嗅字符串**
///
/// 诱惑是从 `reason` 里 grep "mount" 或 "no such file"。不行——那是 R14 的同一个坑：
/// 上游改一个字，分类**无声失效**，supervisor 在错误的时刻放弃，而一切看起来都正常。
/// 要新的分类，就在 `RuntimeError` 上加 case（编译器会逼所有 switch 显式处理）。
extension FailureKind {

    public init(from error: RuntimeError) {
        switch error {
        case .mountSourceUnavailable:
            // ★ **整个 App 的生死线。** mount 源没就绪 = 外置盘/网络卷还没挂上（R13），
            // 要几十秒到几分钟。这一档退避重试到底、**永不计入熔断**——
            // 判成 .transient 的话，退避 1→2→4→8→16 秒意味着五次失败只花 31 秒，
            // supervisor 会在 31 秒后熔断放弃，正好死在它唯一该活着的那一刻。
            self = .environmentNotReady

        case .runtimeUnavailable:
            // 运行时自己死了**不是容器 crashloop 的证据**。拿它推熔断计数，
            // 等于「apiserver 抖几下，supervisor 就永久放弃」。
            //
            // 这条失败债本来也活不长：probe 很快会看到 down，reducer 在 `.runtimeDown`
            // 那一格把整串 streak 丢掉（换代 = 全新局面）。
            self = .environmentNotReady

        case .containerNotFound:
            // 白名单 ID 拼错了，或者容器被 `container delete` 删了。**重试一万次也没用。**
            // 归进可重试档，只会把日志刷满，并让真正的问题埋在噪音里。
            self = .permanent

        case .operationFailed:
            // 这一档才是熔断要防的东西：容器起来就崩、崩了又被拉起。
            self = .transient
        }
    }
}
