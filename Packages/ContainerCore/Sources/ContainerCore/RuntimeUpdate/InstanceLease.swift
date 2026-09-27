import Darwin
import Foundation

/// 运行时更新器的**单实例租约**（Day 22 R2 O）。
///
/// 意图记录住在 defaults 里，同一 bundle id 的两个进程（Xcode 跑的 DEBUG 构建 + /Applications 里的安装版、`open -n`）共用它：
/// B 启动时的恢复流程会把 A 正在进行的升级记录当成崩溃残留，锁一空闲两边都去起运行时、起同一个容器。
/// 拿到租约的实例才接管更新器；拿不到的只读（不恢复、不检查、不安装、不启动运行时）。
///
/// 用 `flock` 而不是「pid + 启动时间」令牌：锁跟着打开的文件描述走，**进程一死内核就释放**——没有 pid 复用、没有陈旧锁要判。
/// fd 由本对象持有到进程结束（`AppModel` 强引用它）。
public final class InstanceLease: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// 另一个实例持着租约。
        case heldByAnotherInstance
        /// 租约文件不可信（符号链接 / 不是普通文件 / 属主不是自己 / group 或 other 可写）——宁可当成拿不到。
        case unsafeFile(String)
        case io(Int32)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)   // 关掉即释放 flock
    }

    /// 生产位置：与白名单同一个目录（`~/Library/Application Support/CradleOfFilth/`，由 `WhitelistStore` 唯一定义）——
    /// DEBUG 构建与安装版共用它，正是要互斥的那两个。
    public static func defaultURL() -> URL {
        WhitelistStore.default().url.deletingLastPathComponent().appendingPathComponent("runtime-update.lease")
    }

    /// 本实例在更新器里的角色。
    public struct Claim {
        /// 持有中的租约（调用方要强引用它到进程结束）；拿不到时为 nil。
        public let lease: InstanceLease?
        public let isPrimary: Bool
        public let failure: Failure?
    }

    /// 取租约并定角色（R3 P2-6a）：**只有另一个实例持着**才只读。租约文件坏了（属主不对、非普通文件、I/O 错）
    /// ≠ 有别的实例——那样只读会让唯一的实例永久失去复原能力，还显示「另一个实例正在管理」这种误导的提示。
    /// 这时照常当主实例（租约只防罕见的双实例竞态），由调用方记日志。
    public static func claim(at url: URL) -> Claim {
        switch acquire(at: url) {
        case .success(let lease):
            Claim(lease: lease, isPrimary: true, failure: nil)
        case .failure(.heldByAnotherInstance):
            Claim(lease: nil, isPrimary: false, failure: .heldByAnotherInstance)
        case .failure(let failure):
            Claim(lease: nil, isPrimary: true, failure: failure)
        }
    }

    public static func acquire(at url: URL) -> Result<InstanceLease, Failure> {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            let code = errno
            return .failure(code == ELOOP ? .unsafeFile("symlink") : .io(code))
        }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            return .failure(.io(code))
        }
        let problem: String? =
            if info.st_mode & S_IFMT != S_IFREG { "not a regular file" }
            else if info.st_uid != getuid() { "owner \(info.st_uid)" }
            else if info.st_mode & (S_IWGRP | S_IWOTH) != 0 { "group/other writable" }
            else { nil }
        if let problem {
            close(fd)
            return .failure(.unsafeFile(problem))
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            return .failure(code == EWOULDBLOCK ? .heldByAnotherInstance : .io(code))
        }
        return .success(InstanceLease(descriptor: fd))
    }
}
