import Foundation
@testable import LumeKit

/// Scripted `CommandRunning` for SSH-layer tests: returns canned results in
/// FIFO order and records every invocation for assertions.
actor FakeCommandRunner: CommandRunning {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let stdin: String?
    }

    private var queue: [Result<CommandResult, Error>]
    private(set) var calls: [Call] = []

    init(results: [Result<CommandResult, Error>] = []) {
        self.queue = results
    }

    static func ok(_ stdout: String = "") -> Result<CommandResult, Error> {
        .success(CommandResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data()))
    }

    static func fail(_ stderr: String, exitCode: Int32 = 1) -> Result<CommandResult, Error> {
        .success(CommandResult(exitCode: exitCode, stdout: Data(), stderr: Data(stderr.utf8)))
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?,
             environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments,
                          stdin: stdin.map { String(decoding: $0, as: UTF8.self) }))
        let next = queue.isEmpty ? nil : queue.removeFirst()
        switch next {
        case .success(let result): return result
        case .failure(let error): throw error
        case nil: return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }
}
