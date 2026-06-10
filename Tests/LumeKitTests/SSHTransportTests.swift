import Testing
import Foundation
@testable import LumeKit

struct SSHTransportTests {
    private func makeTransport(_ runner: FakeCommandRunner,
                               host: SSHHost = SSHHost(alias: "web1")) -> SSHTransport {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHTransportTests-\(UUID().uuidString)")
        return SSHTransport(host: host, runner: runner, controlDir: dir)
    }

    @Test func connectRunsBackgroundedMasterWithControlOptions() async throws {
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        let transport = makeTransport(runner)
        try await transport.connect()
        let call = (await runner.calls)[0]
        #expect(call.executable == "/usr/bin/ssh")
        #expect(call.arguments.contains("ControlMaster=auto"))
        #expect(call.arguments.contains(where: { $0.hasPrefix("ControlPath=") && $0.hasSuffix("web1.sock") }))
        #expect(call.arguments.suffix(2) == ["-fN", "web1"])
    }

    @Test func connectMapsAuthFailure() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("manu@web1: Permission denied (publickey)."),
        ])
        let transport = makeTransport(runner)
        await #expect(throws: SSHError.authFailed) { try await transport.connect() }
    }

    @Test func manualHostFlagsAndDestination() async throws {
        let host = SSHHost(alias: "prod", hostname: "10.0.0.5", user: "deploy", port: 2222)
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        try await makeTransport(runner, host: host).connect()
        let args = (await runner.calls)[0].arguments
        #expect(args.contains("-p") && args.contains("2222"))
        #expect(args.last == "deploy@10.0.0.5")
    }

    @Test func slashAliasSanitizedInControlPath() async throws {
        let host = SSHHost(alias: "prod/web:1")
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        try await makeTransport(runner, host: host).connect()
        let args = (await runner.calls)[0].arguments
        #expect(args.contains(where: { $0.hasPrefix("ControlPath=") && $0.hasSuffix("prod-web-1.sock") }))
    }

    @Test func sftpFeedsBatchOverStdinWithCapitalPortFlag() async throws {
        let host = SSHHost(alias: "prod", hostname: "10.0.0.5", port: 2222)
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok("listing")])
        let out = try await makeTransport(runner, host: host).sftp(["ls -la /etc"])
        #expect(out == "listing")
        let call = (await runner.calls)[0]
        #expect(call.executable == "/usr/bin/sftp")
        #expect(call.stdin == "ls -la /etc\n")
        #expect(call.arguments.contains("-P") && call.arguments.contains("2222"))
        #expect(call.arguments.contains("-b"))
    }

    @Test func sftpReconnectsOnceWhenMasterDied() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("Connection closed by remote host"),  // sftp #1
            FakeCommandRunner.ok(),                                       // reconnect ssh -fN
            FakeCommandRunner.ok("recovered"),                            // sftp #2
        ])
        let out = try await makeTransport(runner).sftp(["pwd"])
        #expect(out == "recovered")
        #expect((await runner.calls).map(\.executable) ==
                ["/usr/bin/sftp", "/usr/bin/ssh", "/usr/bin/sftp"])
    }

    @Test func sftpSurfacesPermissionDeniedWithoutRetry() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail(#"remote open("/etc/x"): Permission denied"#),
        ])
        let transport = makeTransport(runner)
        await #expect(throws: SSHError.permissionDenied(path: "/etc/x")) {
            _ = try await transport.sftp(["put a /etc/x"], path: "/etc/x")
        }
        #expect((await runner.calls).count == 1)
    }
}
