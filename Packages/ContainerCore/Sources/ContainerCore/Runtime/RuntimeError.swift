/// 运行时操作的失败。**这是 domain 侧看得见的全部失败形态**——
/// 上游的 `ContainerizationError` / XPC 错误到 mapper 为止（D1）。
///
/// ## `runtimeUnavailable` 的判定权不在 XPC 错误手里（R14）
///
/// 诱惑是「XPC 连不上 → 运行时挂了」。**不行**：XPC 连接失败有一堆别的原因
/// （launchd 还没 on-demand 拉起 apiserver、Mach service 名字对不上、瞬时抖动），
/// 而 supervisor 把它们全当成「运行时换代了」就会去重启一堆本来好好的容器。
///
/// 判定权归 `RuntimeProber`（Day 5，libproc 直接读 apiserver 进程的 `(pid, startTime)`）。
/// **XPC 错误只是提示，进程表才是事实。** mapper 只在 prober 也确认进程不在时，
/// 才把上游错误映射成这个 case。
///
/// ## 每个 case 都必须有真实的产生者
///
/// M0 只有两个（Fake 注入 + 白名单里写了个不存在的 ID）。Day 5 加了两个——
/// 不是为了「更完整」，是因为 supervisor 的**失败三分类**（`FailureKind`）
/// 每一档都需要产生者，否则熔断路径和 R13 路径根本没法被测到。
///
/// 加 case 会让所有穷尽 `switch` **编译报错**，逼每个消费者显式决定怎么处理。
/// 那正是想要的：新的失败形态不该被一个既有的 `default:` 分支静默吞掉。
///
/// 映射到 supervisor 的反应，见 `FailureClassification.swift`——**那张表是 R13 的生死线**。
public enum RuntimeError: Error, Equatable, Sendable {

    /// apiserver 不在（由 `RuntimeProber` 查进程表判定，不由 XPC 错误判定）。
    case runtimeUnavailable

    /// 这个 ID 的容器不存在。
    ///
    /// 必须与 `runtimeUnavailable` 分开：supervisor 对两者的反应完全相反——
    /// 运行时挂了要**等它回来再重试**；容器不存在（用户白名单里 ID 拼错了、
    /// 或者容器被 `container delete` 删了）则**重试一万次也没用**，该报给用户。
    /// 混为一谈，supervisor 会对着一个永远不会出现的容器无限重试。
    case containerNotFound(ContainerID)

    /// ★ **R13 的落点。** virtiofs mount 的源路径在宿主上还不存在。
    ///
    /// 官方 `container start` 在 bootstrap 之前逐个校验 mount 源路径（已核实源码），
    /// 校验不过容器就起不来。而**这正是「Mac 重启之后」的高发情形**：外置盘、网络卷
    /// 要几十秒到几分钟才挂上——也就是 supervisor 最该坚持的那几分钟。
    ///
    /// 它必须是**独立的 case**，不能混进 `.operationFailed`：
    /// 后者判成 `.transient` → 计入熔断 → 五次失败只花 31 秒 → 熔断放弃。
    /// **本 App 的全部价值当场归零，而且编译绿、测试绿、看不出任何异常。**
    ///
    /// - Parameter path: 缺失的源路径。给用户看的（「把那块盘插上」），
    ///   **不参与任何判断**——判断只看 case 本身。
    case mountSourceUnavailable(path: String)

    /// 操作失败了，原因不属于上面任何一类。**这一档才是熔断要防的东西**
    /// （容器起来就崩、崩了又被拉起——crashloop 打铁）。
    ///
    /// - Parameter reason: 上游给的说法。**只用于展示与日志，绝不用于分类**——
    ///   靠嗅字符串分类，上游改一个字就无声失效（R14 的同一条教训）。
    case operationFailed(reason: String)
}
