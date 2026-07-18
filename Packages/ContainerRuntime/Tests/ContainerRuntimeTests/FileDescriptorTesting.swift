import Foundation

/// 测试专用：判断一个 `FileHandle` 是否已经被关闭。
///
/// ## 为什么不查裸 fd 号（`fcntl(fd, F_GETFD)`）
///
/// 第一版就是这么写的，**在同一个测试进程里并发跑别的 suite 时会假失败**：
/// fd 号是进程级共享资源，我们这边刚 `close()`，另一个 suite 读 fixture JSON
/// （`Data(contentsOf:)`）几乎同时开了个新文件，操作系统把同一个号立刻发给它——
/// 断言撞见的是那个无关的、恰好同号的新 fd，判成「还开着」。实测在这个仓库里
/// 复现过：单独跑这个 suite 稳定通过，跟其他 suite 一起跑就稳定失败在同一条断言上。
///
/// `FileHandle` 自己维护「有没有被关过」这份状态，不依赖 OS 的 fd 号有没有被回收——
/// `close()` 之后再 `read` 会抛错，且这个行为在 fd 号被别的资源复用之后依然成立
/// （已用一个「关闭后强制让别的 Pipe 抢到同一个号，再读」的脚本验证过）。
///
/// 调用方须知：这个函数会尝试读 1 字节。若 handle **确实还开着**且暂时没有数据、
/// 写端也还没关，`read` 会阻塞到有数据或写端关闭为止——调用方应当只在预期
/// 「这里应该已经关了」的地方用它，并给测试挂 `.timeLimit`，让一次意外的阻塞
/// 变成响亮的超时失败，而不是静默卡死整个测试进程。
func isClosed(_ handle: FileHandle) -> Bool {
    do {
        _ = try handle.read(upToCount: 1)
        return false
    } catch {
        return true
    }
}

/// 轮询直到条件成立或超时——fd 的关闭发生在 `onTermination` 回调里，
/// 那个回调本身是异步触发的（不是调用 `cancel()` 那一刻就同步生效），
/// 所以断言「已经关闭」需要给一点点时间窗口，而不是立刻判定。
func waitUntil(
    timeout: Duration = .seconds(2),
    poll: Duration = .milliseconds(5),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: poll)
    }
}
