import Testing

@testable import ContainerCore

/// 删 volume 的门槛必须和 CLI 一样严——这些测试钉死「什么算打对了」。
@Suite("TypedConfirmation")
struct TypedConfirmationTests {

    @Test("完全一致 → 放行")
    func exactMatchConfirms() {
        #expect(TypedConfirmation.canConfirm(typed: "my-data", expected: "my-data"))
    }

    @Test("大小写不同 → 拦住")
    func caseSensitive() {
        #expect(!TypedConfirmation.canConfirm(typed: "My-Data", expected: "my-data"))
    }

    @Test("首尾多了普通空格 → 拦住（不 trim 空格）")
    func doesNotTrimSpaces() {
        #expect(!TypedConfirmation.canConfirm(typed: " my-data", expected: "my-data"))
        #expect(!TypedConfirmation.canConfirm(typed: "my-data ", expected: "my-data"))
    }

    @Test("期望名字本身首尾带空格 → 必须原样打出来")
    func spaceInExpectedMustBeTyped() {
        #expect(TypedConfirmation.canConfirm(typed: " spaced ", expected: " spaced "))
        #expect(!TypedConfirmation.canConfirm(typed: "spaced", expected: " spaced "))
    }

    @Test("首尾换行被去掉（输入框 / 粘贴带进来的看不见字符）")
    func trimsNewlinesOnly() {
        #expect(TypedConfirmation.canConfirm(typed: "my-data\n", expected: "my-data"))
        #expect(TypedConfirmation.canConfirm(typed: "\nmy-data", expected: "my-data"))
    }

    @Test("空期望值 → 永不放行（没有靶子的确认框不该通过）")
    func emptyExpectedNeverConfirms() {
        #expect(!TypedConfirmation.canConfirm(typed: "", expected: ""))
    }

    @Test("差一个字 → 拦住")
    func nearMissRejected() {
        #expect(!TypedConfirmation.canConfirm(typed: "my-dat", expected: "my-data"))
    }
}
