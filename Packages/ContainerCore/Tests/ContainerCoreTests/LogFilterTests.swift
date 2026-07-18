import Testing

@testable import ContainerCore

@Suite("LogFilter：对快照做子串过滤的纯函数")
struct LogFilterTests {

    static func line(_ id: Int, _ text: String) -> RedactedLogLine {
        RedactedLogLine(id: id, text: text, source: .stdout)
    }

    @Test("nil options → 原样返回全部")
    func returnsAllWhenOptionsIsNil() {
        let lines = [Self.line(0, "hello"), Self.line(1, "world")]
        #expect(LogFilter.apply(nil, to: lines) == lines)
    }

    @Test("空 query → 原样返回全部")
    func returnsAllWhenQueryIsEmpty() {
        let lines = [Self.line(0, "hello")]
        let options = LogFilter.Options(query: "")
        #expect(LogFilter.apply(options, to: lines) == lines)
    }

    @Test("默认大小写不敏感")
    func defaultsToCaseInsensitive() {
        let lines = [Self.line(0, "Hello World")]
        let options = LogFilter.Options(query: "hello")
        #expect(LogFilter.apply(options, to: lines).count == 1)
    }

    @Test("caseSensitive: true → 大小写必须完全匹配")
    func caseSensitiveRequiresExactCase() {
        let lines = [Self.line(0, "Hello World")]
        let options = LogFilter.Options(query: "hello", caseSensitive: true)
        #expect(LogFilter.apply(options, to: lines).isEmpty)
    }

    @Test("没有命中 → 空数组")
    func returnsEmptyWhenNoMatch() {
        let lines = [Self.line(0, "hello"), Self.line(1, "world")]
        let options = LogFilter.Options(query: "nope")
        #expect(LogFilter.apply(options, to: lines).isEmpty)
    }

    @Test("只保留命中的行，顺序不变")
    func keepsOnlyMatchingLinesInOrder() {
        let lines = [Self.line(0, "alpha"), Self.line(1, "beta"), Self.line(2, "alphabet")]
        let options = LogFilter.Options(query: "alpha")

        let filtered = LogFilter.apply(options, to: lines)

        #expect(filtered.map(\.id) == [0, 2])
    }
}
