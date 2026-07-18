import Testing
import ContainerCore

/// 复制密钥时剪贴板上该有什么，在这里被钉死。
///
/// Day 11 真机取证的教训：`org.nspasteboard.ConcealedType` 是给剪贴板管理器看的
/// **附加标记**，不是 `.string` 的替代——只写标记，`pbpaste` 与所有粘贴目标读到的
/// 都是空，「复制」功能整个是死的（E1 实测：`setString` 返回 true、类型在场、
/// `.string` 读回 nil）。这两条测试分别守住功能的两半：
/// - 粘贴目标读得到（plain text 在场且值是明文）；
/// - 剪贴板管理器认得出（concealed 标记在场）。
struct ConcealedCopyPayloadTests {

    private let plaintext = "secret-plaintext"

    @Test("payload 含 plain-text 条目——没有它，任何 App 都粘不出来")
    func containsPastablePlainText() {
        let entries = ConcealedCopyPayload.entries(for: plaintext)

        #expect(entries.contains(
            ConcealedCopyPayload.Entry(type: ConcealedCopyPayload.plainTextType, value: plaintext)
        ))
    }

    @Test("payload 含 concealed 标记——没有它，明文进剪贴板历史")
    func containsConcealedMarker() {
        let entries = ConcealedCopyPayload.entries(for: plaintext)

        #expect(entries.contains { $0.type == ConcealedCopyPayload.concealedMarkerType })
    }

    @Test("payload 只有这两类条目——不多写一个类型，泄漏面不扩大")
    func containsNothingElse() {
        let types = ConcealedCopyPayload.entries(for: plaintext).map(\.type)

        #expect(Set(types) == [
            ConcealedCopyPayload.plainTextType,
            ConcealedCopyPayload.concealedMarkerType,
        ])
    }
}
