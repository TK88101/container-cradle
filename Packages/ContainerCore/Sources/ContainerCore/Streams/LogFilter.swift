import Foundation

/// 对 `LogRingBuffer.snapshot()` 做子串过滤的纯函数。**view 保持愚蠢**（Day 9 计划 D-C）：
/// 过滤逻辑住这里，view 只管把 `Options` 从搜索框搬过来。
public enum LogFilter {

    public struct Options: Sendable, Equatable {
        public let query: String
        public let caseSensitive: Bool

        public init(query: String, caseSensitive: Bool = false) {
            self.query = query
            self.caseSensitive = caseSensitive
        }
    }

    /// `options` 为 `nil` 或 `query` 为空 → 原样返回全部（「没有过滤条件」）。
    public static func apply(_ options: Options?, to lines: [RedactedLogLine]) -> [RedactedLogLine] {
        guard let options, !options.query.isEmpty else { return lines }

        return lines.filter { line in
            options.caseSensitive
                ? line.text.contains(options.query)
                : line.text.range(of: options.query, options: .caseInsensitive) != nil
        }
    }
}
