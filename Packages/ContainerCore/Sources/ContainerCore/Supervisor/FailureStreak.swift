import Foundation

/// 一连串失败。**两个计数，两条生命线，别把它们绑在一起。**
///
/// ## 为什么退避和熔断不能共用一个数
///
/// 「该等多久再试」和「该不该放弃」问的不是同一个问题：
///
/// - **退避档位**要把 `.environmentNotReady` 数进去。不数，档位永远停在第 1 档（1 秒）——
///   外置盘迟迟不挂上时，supervisor 会每秒重试一次，试一整天。
/// - **熔断计数**绝不能把它数进去。数了，五次失败只花 31 秒就熔断
///   （退避 1+2+4+8+16 = 31s），而外置盘要几分钟才就绪——supervisor 死在它唯一该活着的那一刻（R13）。
///
/// ## 为什么熔断要存**时间戳**，不能只存一个计数 + 一个窗口起点
///
/// 熔断的判据是「**10 分钟内**失败 5 次」——这是个**滑动**窗口，不是**翻页**窗口。
///
/// 只记「这串从什么时候开始」，过期时就只能把整串扔掉重来。于是失败发生在
/// 0s / 590s / 610s / 620s / 630s / 640s 时：610s 那次因为距锚点 0s 超过了 600s，
/// 会把**仍在窗口内的 590s 那次一起扔掉**——最后只数到 4 次，不熔断。
/// 可 590s→640s 这 50 秒里崩了 5 次，是标准的 crashloop，恰恰是最该熔断的情形。
///
/// 存时间戳（最多留 threshold 个）就没有这个洞：每次都精确地问「最近 window 内有几次」。
/// 代价是几个 `Date`，换的是熔断真的按它宣称的语义工作。
///
/// ## 而退避档位**不跟着窗口翻页**
///
/// 曾经把它也绑在窗口上——外置盘挂不上超过 10 分钟时，`attempts` 归 1，
/// 退避从 300 秒的上限**掉回 1 秒重新猛冲**（1,2,4,8…），攒够 10 分钟再爆一次。
/// 「一直试下去的成本极低」当场变成谎话。
///
/// 它只在**成功**或**换代**时清零（那时整个 streak 都被丢弃）——
/// 那才是「上一串失败已经不作数了」的真实时刻。
public struct FailureStreak: Equatable, Sendable {

    /// 连续失败了几次（**所有**可重试的失败都算）。退避曲线看这个数。
    ///
    /// 不因熔断窗口过期而重置——见类型文档。
    public let attempts: Int

    /// 最近若干次**计入熔断**的失败（只有 `.transient`）发生的时刻，从旧到新。
    ///
    /// 只保留窗口内、且最多 `threshold` 个——再多也改变不了「够不够阈值」的判断，
    /// 留着只是让状态无止境地长胖。
    public let breakerFailures: [Date]

    public init(attempts: Int, breakerFailures: [Date]) {
        self.attempts = attempts
        self.breakerFailures = breakerFailures
    }

    /// 窗口内、计入熔断的失败次数。
    public var breakerCount: Int { breakerFailures.count }

    /// 记一次新失败。
    ///
    /// - Parameter threshold: 熔断阈值。只用来决定「时间戳最多留几个」——
    ///   超过阈值的历史再精确也没用，判断早就成立了。
    func recording(
        _ kind: FailureKind,
        at now: Date,
        window: TimeInterval,
        threshold: Int
    ) -> FailureStreak {
        guard kind.countsTowardCircuitBreaker else {
            // 环境没就绪不是容器的错，不算它头上。
            // 但退避档位照涨——否则外置盘不挂上就会以最短间隔重试一整天。
            return FailureStreak(
                attempts: attempts + 1,
                breakerFailures: breakerFailures.within(window, of: now)
            )
        }

        let recent = (breakerFailures + [now]).within(window, of: now)

        return FailureStreak(
            attempts: attempts + 1,
            breakerFailures: Array(recent.suffix(max(threshold, 1)))
        )
    }

    /// 一次失败都还没发生。
    ///
    /// 刻意**没有**一个 `first(kind:at:)` 的构造器：它会把「这档算不算熔断」的分岔
    /// 再手写一遍，于是 `recording` 的记账策略哪天变了，那份副本不会跟着变，
    /// 而且**编译器一声不吭**。让首次失败也走 `recording`，只有一条记账路径。
    static let none = FailureStreak(attempts: 0, breakerFailures: [])
}

extension [Date] {

    /// 只留下距 `now` 在 `window` 之内的那些——**滑动**窗口的全部含义就在这一行。
    func within(_ window: TimeInterval, of now: Date) -> [Date] {
        filter { now.timeIntervalSince($0) <= window }
    }
}

extension FailureKind {

    /// 这一档失败算不算「容器自己有问题」的证据。
    ///
    /// 只有 `.transient` 算。`.environmentNotReady` 是**宿主**还没准备好（R13），
    /// 容器是无辜的；`.permanent` 压根走不到熔断（它不重试）。
    var countsTowardCircuitBreaker: Bool {
        switch self {
        case .transient: true
        case .environmentNotReady, .permanent: false
        }
    }
}
