import ContainerCore
import ContainerizationError
import Foundation

/// 上游错误 → `RuntimeError`。**这是 R14 的落点。**
///
/// ## 运行时的死活，由进程表说了算，不由 XPC 错误码说了算
///
/// 实测：apiserver 挂掉时，XPC 报的是
///
/// ```
/// internalError: "failed to list containers"
///   (cause: "interrupted: "XPC connection error: Connection invalid"")
/// ```
///
/// `.internalError` 是个**大杂烩 code**——它跟「launchd 还没 on-demand 拉起 apiserver」
/// 「瞬时抖动」「上游内部 bug」长得一模一样，**没有专门的 unavailable 分类**。
///
/// 于是有两条诱人的错路：
///
/// 1. **「XPC 报错 = 运行时挂了」** → supervisor 会因为一次抖动就断定运行时换代，
///    跑去重启一堆本来好好的容器。
/// 2. **嗅 cause 字符串**（找 `"XPC connection error"`）→ 上游改一个字就失效，**且无声**。
///    分类会在某个上游小版本之后悄悄失准，而测试全绿。
///
/// → **先问 `RuntimeProber`（libproc 直接读进程表），它说 down 才是 down。**
///
/// ## 分类只看 code，不看 message
///
/// `ContainerizationError.message` 只用于展示与日志。拿它做分类是上一条的同一个坑。
struct RuntimeErrorMapper: Sendable {

    private let prober: any RuntimeProber

    init(prober: any RuntimeProber) {
        self.prober = prober
    }

    /// - Parameter containerID: 这次操作针对的容器。`list()` 没有特定目标，传 `nil`——
    ///   于是 `.notFound` 在 list 路径上不会被误报成「某个容器不存在」。
    func map(_ error: any Error, containerID: ContainerID?) async -> RuntimeError {

        // 我们自己抛的 domain 错误原样放行。**这一条不是形式主义**：
        // `.mountSourceUnavailable` 若在这里被重新包装成 `.operationFailed`，
        // 它就会被判成 `.transient` → 计入熔断 → **31 秒后放弃**，
        // Day 4 + Day 5 全白做（CLAUDE.md：这条链子只要有一环接错，整条就断了，且全绿）。
        if let runtimeError = error as? RuntimeError {
            return runtimeError
        }

        // 取消是**我们自己**发起的，与运行时死活无关——不必去问进程表。
        if error is CancellationError {
            return .operationFailed(reason: "Operation was cancelled")
        }

        // ★★ R14：进程表是唯一权威，**它必须先跑**。
        //
        // 这一句原本在超时判断的**后面**，于是超时永远走不到它（codex review 抓到的）。
        // 而注释还写着「真挂了的话，下面那句 probe 自然会说 down」——**注释和代码不符**，
        // 是这一轮的第二次了。
        //
        // 漏掉的场景很具体：XPC 的 5 秒超时窗口**之内**，apiserver 死掉（进程消失）。
        // 我们看到的是「超时」，而真相是「运行时没了」。判成 `.operationFailed` →
        // `.transient` → **计入熔断**，可 `FailureClassification` 的原则正相反：
        // **运行时自己死了不是容器 crashloop 的证据**，它该归 `.environmentNotReady`。
        //
        // 代价是每个错误都多一次 probe——libproc 读进程表，微秒级、零 XPC，可忽略。
        if await prober.probe() == .down {
            return .runtimeUnavailable
        }

        // 到这里，进程表说 apiserver 还活着。超时于是就只是超时（对端僵死 / 忙）——
        // 归 `.operationFailed` → `.transient` → 走退避 + 计入熔断（R5 要的正是这个：
        // 持续超时说明运行时病了，熔断报警要人工介入）。
        if let timeout = error as? XPCTimeout.TimedOut {
            return .operationFailed(reason: "XPC call timed out (\(timeout.after))")
        }

        guard let upstream = error as? ContainerizationError else {
            return .operationFailed(reason: String(describing: error))
        }

        // `get(id:)` 在容器不存在时抛 `.notFound`（已核实源码：ContainerClient.swift:112）。
        // 注意 `stop()` 对不存在的容器抛的是 `.internalError`（真因埋在 cause 里）——
        // 那条路径落进下面的 `.operationFailed`，这是对的：stop 一个不存在的容器，
        // 对 supervisor 而言不是「白名单 ID 写错了」，而是一次失败的操作。
        if upstream.isCode(.notFound), let containerID {
            return .containerNotFound(containerID)
        }

        return .operationFailed(reason: upstream.message)
    }
}
