import Foundation
import Synchronization

@testable import ContainerCore

/// 按「可执行文件 + 参数」脚本化返回结果的 runner，并记下每一次调用。
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {

    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: Duration?
    }

    private let state = Mutex<(calls: [Call], responses: [[String]: Result<ProcessResult, ProcessRunError>])>(([], [:]))

    /// 没脚本化的调用返回的默认结果。
    let fallback: Result<ProcessResult, ProcessRunError>

    init(fallback: Result<ProcessResult, ProcessRunError> = .success(ProcessResult(exitCode: 0, stdout: "", stderr: ""))) {
        self.fallback = fallback
    }

    func respond(to command: [String], with result: Result<ProcessResult, ProcessRunError>) {
        state.withLock { $0.responses[command] = result }
    }

    func respond(to command: [String], exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        respond(to: command, with: .success(ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func run(_ executable: String, arguments: [String], timeout: Duration?) async throws(ProcessRunError) -> ProcessResult {
        let result = state.withLock { state -> Result<ProcessResult, ProcessRunError> in
            state.calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
            return state.responses[[executable] + arguments] ?? fallback
        }
        return try result.get()
    }
}
