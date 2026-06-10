import Testing
import Foundation
@testable import LumeKit

struct ProcessRunnerTests {
    @Test func capturesStdoutAndExitCode() async throws {
        let result = try await ProcessRunner().run(
            "/bin/echo", ["hello"], stdin: nil, environment: nil, timeout: 10)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func capturesNonzeroExit() async throws {
        let result = try await ProcessRunner().run(
            "/usr/bin/false", [], stdin: nil, environment: nil, timeout: 10)
        #expect(result.exitCode != 0)
    }

    @Test func feedsStdin() async throws {
        let result = try await ProcessRunner().run(
            "/bin/cat", [], stdin: Data("piped".utf8), environment: nil, timeout: 10)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "piped")
    }

    @Test func timesOutAndThrows() async {
        await #expect(throws: SSHError.timeout(executable: "/bin/sleep")) {
            _ = try await ProcessRunner().run(
                "/bin/sleep", ["5"], stdin: nil, environment: nil, timeout: 0.3)
        }
    }
}
