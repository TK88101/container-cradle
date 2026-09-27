import Foundation
import Testing

@testable import ContainerCore

/// Day 22 R2 O：更新器的单实例租约。
@Suite("InstanceLease：flock 租约，进程死即释放，不信可疑文件")
struct InstanceLeaseTests {

    static func failure(_ result: Result<InstanceLease, InstanceLease.Failure>) -> InstanceLease.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    static func held(_ result: Result<InstanceLease, InstanceLease.Failure>) -> InstanceLease? {
        if case .success(let lease) = result { return lease }
        return nil
    }

    @Test("第一个拿到；第二个拿不到；第一个放掉之后又拿得到；新建的文件 0600")
    func exclusiveWithinProcess() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.path("runtime-update.lease"))

        // 第一个租约的生命周期显式限定在这个块里：`#expect(first != nil)` 这类宏会捕获值、把释放推迟到作用域末尾，
        // 「置 nil 即释放」在测试里不可靠（实测偶发红）。块一结束 fd 关闭、flock 释放。
        var firstAcquired = false
        var second: InstanceLease.Failure?
        do {
            let first = InstanceLease.acquire(at: url)
            firstAcquired = Self.held(first) != nil
            second = Self.failure(InstanceLease.acquire(at: url))
            withExtendedLifetime(first) {}
        }
        #expect(firstAcquired)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        #expect(second == .heldByAnotherInstance)
        #expect(Self.held(InstanceLease.acquire(at: url)) != nil)
    }

    /// 另一个进程持着 flock（`lockf` 就是 BSD flock，F14）→ 拿不到；它一退出（进程死 = 锁释放）→ 拿得到。
    @Test("跨进程：别的进程持锁时拿不到，它退出后拿得到")
    func exclusiveAcrossProcesses() async throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.path("runtime-update.lease"))
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", "-s", "-t", "0", url.path, "/bin/sleep", "2"]
        try holder.run()
        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.failure(InstanceLease.acquire(at: url)) == .heldByAnotherInstance)

        holder.waitUntilExitWithoutRunLoop()
        #expect(Self.held(InstanceLease.acquire(at: url)) != nil)
    }

    /// R3 P2-6a：只有「另一个实例持着」才只读；租约文件坏了（属主不对、I/O 错）≠ 有别的实例——
    /// 那样只读会让唯一的实例永久失去恢复能力，还显示误导的提示。
    @Test("claim：另一个实例持有 → 只读；租约文件不可信 → 仍按主实例，但不持有租约")
    func claimDistinguishesReasons() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.path("runtime-update.lease"))
        let first = InstanceLease.claim(at: url)
        #expect(first.isPrimary && first.lease != nil && first.failure == nil)
        let second = InstanceLease.claim(at: url)
        #expect(!second.isPrimary && second.lease == nil && second.failure == .heldByAnotherInstance)

        let bad = URL(fileURLWithPath: dir.path("bad.lease"))
        try FileManager.default.createSymbolicLink(atPath: bad.path, withDestinationPath: url.path)
        let broken = InstanceLease.claim(at: bad)
        #expect(broken.isPrimary && broken.lease == nil && broken.failure == .unsafeFile("symlink"))
    }

    @Test("租约路径是符号链接 → 拒绝（不跟随）")
    func rejectsSymlink() throws {
        let dir = try TempDir()
        let target = dir.path("elsewhere")
        FileManager.default.createFile(atPath: target, contents: nil, attributes: [.posixPermissions: 0o600])
        let url = URL(fileURLWithPath: dir.path("runtime-update.lease"))
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        #expect(Self.failure(InstanceLease.acquire(at: url)) == .unsafeFile("symlink"))
    }

    @Test("既有文件 group / other 可写 → 拒绝")
    func rejectsWritableByOthers() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.path("runtime-update.lease"))
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o620])
        #expect(Self.failure(InstanceLease.acquire(at: url)) == .unsafeFile("group/other writable"))
    }
}
