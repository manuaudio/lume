import Testing
import Foundation
@testable import LumeKit

struct SSHFileSourceWriteTests {
    /// Source with a deterministic temp suffix so batch contents are assertable.
    private func makeSource(_ runner: FakeCommandRunner) -> SSHFileSource {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHWriteTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = SSHHost(alias: "web1")
        let transport = SSHTransport(host: host, runner: runner,
                                     controlDir: dir.appendingPathComponent("ctl"))
        return SSHFileSource(host: host, transport: transport, tempDir: dir,
                             tempSuffix: { "fixed" })
    }

    private let statLine = "-rw-r----- 1 root wheel 2049 Jun  9 10:00 /etc/app/config.yaml"

    @Test func writeStatsThenPutsChmodsRenames() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(statLine),   // stat batch
            FakeCommandRunner.ok(),           // put+chmod+rename batch
        ])
        try await makeSource(runner).write("new contents", to: "/etc/app/config.yaml")

        let calls = await runner.calls
        #expect(calls.count == 2)
        let batch = calls[1].stdin ?? ""
        let lines = batch.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("put \"") )
        #expect(lines[0].hasSuffix("\"/etc/app/config.yaml.lume-tmp-fixed\""))
        #expect(lines[1] == "chmod 640 \"/etc/app/config.yaml.lume-tmp-fixed\"")
        #expect(lines[2] == "rename \"/etc/app/config.yaml.lume-tmp-fixed\" \"/etc/app/config.yaml\"")
    }

    @Test func failedBatchCleansUpTempAndRethrows() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(statLine),                                       // stat
            FakeCommandRunner.fail(#"remote open: Permission denied"#),           // put fails
            FakeCommandRunner.ok(),                                               // cleanup rm
        ])
        let source = makeSource(runner)
        await #expect(throws: SSHError.permissionDenied(path: "/etc/app/config.yaml")) {
            try await source.write("x", to: "/etc/app/config.yaml")
        }
        let calls = await runner.calls
        #expect(calls.count == 3)
        #expect(calls[2].stdin == "rm \"/etc/app/config.yaml.lume-tmp-fixed\"\n")
    }

    @Test func statFailurePropagatesWithoutWriting() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("Couldn't stat remote file: No such file or directory"),
        ])
        let source = makeSource(runner)
        await #expect(throws: SSHError.notFound(path: "/etc/app/config.yaml")) {
            try await source.write("x", to: "/etc/app/config.yaml")
        }
        let calls = await runner.calls
        #expect(calls.count == 1)   // nothing was uploaded
    }

    @Test func localStagingFileIsCleanedUp() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(statLine),
            FakeCommandRunner.ok(),
        ])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHWriteCleanup-\(UUID().uuidString)")
        let host = SSHHost(alias: "web1")
        let transport = SSHTransport(host: host, runner: runner,
                                     controlDir: dir.appendingPathComponent("ctl"))
        let source = SSHFileSource(host: host, transport: transport, tempDir: dir,
                                   tempSuffix: { "fixed" })
        try await source.write("contents", to: "/etc/app/config.yaml")
        // Only the ctl subdir may remain in the staging dir — no leftover upload files.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.filter { $0 != "ctl" }.isEmpty)
    }
}
