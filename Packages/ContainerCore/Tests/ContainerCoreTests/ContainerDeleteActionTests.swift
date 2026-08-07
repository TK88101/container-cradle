import Foundation
import Testing

@testable import ContainerCore

/// T9.4：`ContainerActionStore.delete(id:)` 接线（复用 `run` 骨架）。
/// 成功信号（codex #8）= 返回 true + `error(for:)==nil`；删后 keyed 状态自清（codex #9）；
/// 单飞互斥（并发再 delete 拒）；presentation 英文文案穷尽 switch 编译绿。
@MainActor
@Suite("ContainerActionStore delete")
struct ContainerDeleteActionTests {

    @MainActor final class Bumper { var count = 0 }

    private func container(_ id: String) -> Container {
        Container(id: ContainerID(id)!, image: ImageRef("x")!, state: .running, environment: [])
    }

    private func deleteCallCount(_ calls: [FakeContainerRuntimeClient.Call]) -> Int {
        calls.filter { if case .deleteContainer = $0 { return true } else { return false } }.count
    }

    @Test("delete 成功：容器移除 + 返回 true + error nil + inFlight 清 + onActionCompleted 一次")
    func deleteSucceeds() async {
        let cid = ContainerID("web")!
        let fake = FakeContainerRuntimeClient(containers: [container("web")])
        let bumper = Bumper()
        let store = ContainerActionStore(client: fake) { bumper.count += 1 }

        let accepted = await store.delete(id: cid)

        #expect(accepted == true)
        #expect(store.error(for: cid) == nil)                // 成功信号（codex #8）
        #expect(store.actionInProgress(for: cid) == nil)     // 删后自清（codex #9）
        #expect(bumper.count == 1)
        let remaining = try? await fake.list()
        #expect(remaining?.contains(where: { $0.id == cid }) == false)
    }

    @Test("delete 失败 → error(for:) == .deleteFailed")
    func deleteFails() async {
        let cid = ContainerID("web")!
        let fake = FakeContainerRuntimeClient(containers: [container("web")])
        await fake.inject(.runtimeUnavailable, for: .deleteContainer)
        let store = ContainerActionStore(client: fake) {}

        await store.delete(id: cid)

        #expect(store.error(for: cid) == .deleteFailed(.runtimeUnavailable))
    }

    @Test("并发再 delete 被拒：deleteContainer 只调一次（一真一假）")
    func rejectConcurrentDelete() async {
        let cid = ContainerID("web")!
        let fake = FakeContainerRuntimeClient(containers: [container("web")])
        let store = ContainerActionStore(client: fake) {}

        async let a = store.delete(id: cid)
        async let b = store.delete(id: cid)
        let ra = await a
        let rb = await b

        #expect([ra, rb].contains(true))
        #expect([ra, rb].contains(false))
        #expect(deleteCallCount(await fake.calls) == 1)
    }

    @Test("presentation：.deleteFailed 有非空英文文案（穷尽 switch 编译绿）")
    func deletePresentation() {
        let msg = ContainerActionPresentation.message(
            for: .deleteFailed(.runtimeUnavailable),
            locale: Locale(identifier: "en")
        )
        #expect(!msg.isEmpty)
        #expect(msg.hasPrefix("Delete failed"))
    }
}
