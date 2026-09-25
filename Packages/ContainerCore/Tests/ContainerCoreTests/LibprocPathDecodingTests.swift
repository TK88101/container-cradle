import Testing

@testable import ContainerCore

/// v0.3.3 W1：`String(cString: [CChar])` 在 Swift 6 语言模式下已弃用，由 `LibprocProcessTable.decodePath(_:)` 接替。
///
/// 要守住的语义**以 stdlib 源码为准**（那个被弃用的 init：先 `firstIndex(of: 0)`，再 `_fromUTF8Repairing`）：
/// ① 截断在**第一个** NUL；② 非法 UTF-8 修成 U+FFFD，不丢字节，也不失败。
///
/// 这不是抠字眼。内核写回 `proc_pidpath` 缓冲区时写的是**整块**：第一个 NUL 之后还跟着
/// 路径后缀的残留副本（2026-09-25 本机实测，972/972 个进程都是这样）。截错位置不会报错，
/// 只会让进程路径静默带上垃圾——而 apiserver 的识别，靠的就是路径完全相等。
@Suite("LibprocProcessTable.decodePath —— 截断与修复语义对齐被弃用的 String(cString:)")
struct LibprocPathDecodingTests {

    // MARK: - 边界向量

    @Test("截断在第一个 NUL：之后的字节（包括第二个 NUL）一律不要")
    func truncatesAtFirstNUL() {
        let buffer = Array("/a/b".utf8) + [0] + Array("junk".utf8) + [0]

        #expect(LibprocProcessTable.decodePath(buffer) == "/a/b")
    }

    @Test("开头就是 NUL → 空串")
    func leadingNULIsEmpty() {
        #expect(LibprocProcessTable.decodePath([0, 0x2F, 0x61, 0]) == "")
    }

    @Test("多字节 UTF-8 原样保留")
    func keepsMultibyteUTF8() {
        let path = "/Applications/日本語 App.app"

        #expect(LibprocProcessTable.decodePath(Array(path.utf8) + [0]) == path)
    }

    @Test(
        "非法 UTF-8 → 修复结果与 oracle 逐字节相同，且确实出现了 U+FFFD",
        arguments: [
            [0x2F, 0xFF, 0x61, 0x00],        // 孤立的 0xFF
            [0x2F, 0xE6, 0x97, 0x00],        // 3 字节序列被 NUL 截断
            [0xC0, 0xAF, 0x00],              // overlong 编码的 '/'
            [0xED, 0xA0, 0x80, 0x00],        // 代理区码点（UTF-8 里非法）
            [0xF4, 0x90, 0x80, 0x80, 0x00],  // 超出 U+10FFFF
        ] as [[UInt8]]
    )
    func repairsInvalidUTF8LikeOracle(_ buffer: [UInt8]) {
        #expect(Self.agreesWithOracle(buffer))
        #expect(LibprocProcessTable.decodePath(buffer).unicodeScalars.contains("\u{FFFD}"))
    }

    /// 内核实际写回的形状：路径 + NUL + 一段 0 + 路径后缀的残留副本 + 最后一个字节为 NUL。
    /// 截到最后一个 NUL，或者不截断，都会把 `r-apiserver` 这段残留拼进结果。
    @Test("内核真实形状的 4096 字节缓冲区 → 只取到路径本身")
    func kernelShapedBuffer() {
        let path = Array("/usr/local/bin/container-apiserver".utf8)
        let residue = Array(path.suffix(11))
        let padding = [UInt8](repeating: 0, count: 4096 - path.count - residue.count - 1)

        #expect(LibprocProcessTable.decodePath(path + padding + residue + [0]) == "/usr/local/bin/container-apiserver")
    }

    /// 合法多字节序列被 NUL 从中间切断，是随机样本几乎采不到的边界。
    /// 在每个位置各切一刀：NUL 前的半截走修复，NUL 后的半截必须丢掉。
    @Test("合法的 2/3/4 字节序列在每个位置被 NUL 切断 → 与 oracle 逐字节一致")
    func legalSequencesCutAtEveryPosition() {
        for scalar in ["é", "語", "🚀"] {
            let encoded = Array(scalar.utf8)
            for cut in 0...encoded.count {
                let buffer = [0x2F] + encoded[..<cut] + [0] + encoded[cut...] + [0]

                #expect(Self.agreesWithOracle(buffer), "scalar \(scalar) cut at \(cut)")
            }
        }
    }

    /// 旧实现走到这里会 `_preconditionFailure`；这里改成解码整块，这是**刻意的分歧**。
    /// 生产路径上，`record(for:)` 多申请的哨兵字节保证缓冲区里一定有 NUL，走不到这一支。
    @Test("缓冲区里没有 NUL → 整块解码（照样修复非法 UTF-8），不 trap")
    func noNULDecodesWholeBuffer() {
        #expect(LibprocProcessTable.decodePath([0x2F, 0x61]) == "/a")
        #expect(LibprocProcessTable.decodePath([0x2F, 0xFF]) == "/\u{FFFD}")
        #expect(LibprocProcessTable.decodePath([]) == "")
    }

    // MARK: - 差分

    /// 由 14 个边界字节组成的全部 0…3 字节序列，末尾补 NUL，一共 2955 个样本。边界字节涵盖：
    /// NUL、ASCII、续字节的上下界、非法首字节、2/3/4 字节首字节、代理区前导、码点上界。
    /// 确定性穷举，天然可复现。另有一次性的大穷举（8,625,920 个输入，拿被弃用的 API 本体当 oracle，
    /// 0 个分歧），记在 Docs/plans/2026-09-25-v0.3.3-release.md 的 F9。
    @Test("穷举差分：边界字母表上的全部 0…3 字节序列，与 oracle 逐字节一致")
    func exhaustiveDifferentialOverBoundaryAlphabet() {
        for length in 0...3 {
            for sequence in Self.sequences(ofLength: length) {
                guard Self.agreesWithOracle(sequence + [0]) else {
                    Issue.record("与 oracle 分歧：\(sequence)")
                    return
                }
            }
        }
    }

    // MARK: - 辅助

    private static let boundaryAlphabet: [UInt8] = [
        0x00, 0x2F, 0x61, 0x7F, 0x80, 0xBF, 0xC0, 0xC2, 0xE0, 0xE6, 0xED, 0xF0, 0xF4, 0xFF,
    ]

    private static func sequences(ofLength length: Int) -> [[UInt8]] {
        (0..<length).reduce([[]]) { prefixes, _ in
            prefixes.flatMap { prefix in boundaryAlphabet.map { prefix + [$0] } }
        }
    }

    /// 按 UTF-8 字节比较，不用 `==`：String 的 `==` 按规范等价判等，会把 NFC 和 NFD 当成相同。
    private static func agreesWithOracle(_ buffer: [UInt8]) -> Bool {
        Array(LibprocProcessTable.decodePath(buffer).utf8) == Array(oracle(buffer).utf8)
    }

    /// oracle 用未弃用的**指针**重载，stdlib 里它同样是「strlen 截断 + `_fromUTF8Repairing`」。
    /// **只能喂含 NUL 的缓冲区**：没有 NUL 时，strlen 会越界读。
    private static func oracle(_ buffer: [UInt8]) -> String {
        precondition(buffer.contains(0), "oracle 只接受含 NUL 的缓冲区")
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
