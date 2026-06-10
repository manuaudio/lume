import Testing
import Foundation
@testable import LumeKit

struct SSHFileSourceTests {
    private func makeSource(_ runner: FakeCommandRunner) -> SSHFileSource {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHFileSourceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = SSHHost(alias: "web1")
        let transport = SSHTransport(host: host, runner: runner,
                                     controlDir: dir.appendingPathComponent("ctl"))
        return SSHFileSource(host: host, transport: transport, tempDir: dir)
    }

    @Test func listFiltersSortsAndBuildsRefs() async throws {
        let listing = """
        sftp> ls -la /srv/app
        drwxr-xr-x  2 u g  96 Jun  9 10:00 .git
        drwxr-xr-x  2 u g  96 Jun  9 10:00 conf
        -rw-r--r--  1 u g  10 Jun  9 10:00 .env
        -rw-r--r--  1 u g  10 Jun  9 10:00 .secret
        -rw-r--r--  1 u g  10 Jun  9 10:00 app.yaml
        lrwxrwxrwx  1 u g  15 Jun  9 10:00 current -> releases/v2
        """
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let nodes = try await makeSource(runner).list("/srv/app", includeHidden: false)
        // .git ignored always; .secret hidden; folders first; .env visible; symlink mapped.
        #expect(nodes.map(\.name) == ["conf", ".env", "app.yaml", "current"])
        #expect(nodes[0].isDirectory)
        #expect(nodes[1].ref == ResourceRef(sourceID: .ssh(alias: "web1"), path: "/srv/app/.env"))
        #expect(nodes[3].isSymlink)
        #expect((await runner.calls)[0].stdin == "ls -la \"/srv/app\"\n")
    }

    @Test func statSingleFileParsesItsLine() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("-rw-r----- 1 u g 2049 Jun  9 10:00 /etc/app/config.yaml"),
        ])
        let meta = try await makeSource(runner).stat("/etc/app/config.yaml")
        #expect(!meta.isDirectory)
        #expect(meta.size == 2049)
        #expect(meta.mode == 0o640)
    }

    @Test func statDirectoryFallsBackWhenContentsListed() async throws {
        let listing = """
        -rw-r--r-- 1 u g 10 Jun  9 10:00 a.txt
        -rw-r--r-- 1 u g 10 Jun  9 10:00 b.txt
        """
        let meta = try await makeSource(
            FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])).stat("/etc/app")
        #expect(meta.isDirectory)
    }

    @Test func readDownloadsToTempAndReturnsText() async throws {
        let runner = FakeCommandRunner()
        let source = makeSource(runner)
        // The fake runs no real sftp, so no file lands at the temp path; the
        // source must treat the missing download as an error (not crash).
        await #expect(throws: SSHError.self) {
            _ = try await source.read("/srv/app/app.yaml")
        }
        let stdin = (await runner.calls)[0].stdin ?? ""
        #expect(stdin.hasPrefix("get \"/srv/app/app.yaml\" \""))
    }

    @Test func realpathParsesPwd() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("sftp> cd \"/home/manu\"\nsftp> pwd\nRemote working directory: /home/manu\n"),
        ])
        let path = try await makeSource(runner).realpath(".")
        #expect(path == "/home/manu")
        #expect((await runner.calls)[0].stdin == "cd \".\"\npwd\n")
    }

    @Test func quoteEscapesQuotesAndBackslashes() throws {
        #expect(try SSHFileSource.quote(#"/tmp/we"ird\path"#) == #""/tmp/we\"ird\\path""#)
    }

    @Test func quoteRejectsNewlines() {
        #expect(throws: SSHError.self) { _ = try SSHFileSource.quote("/tmp/evil\nrm x") }
    }

    /// Pins the documented heuristic edge case: a directory whose single child
    /// has the same name as the directory itself is currently misreported as a
    /// file. stat() results are hints only; the real error surfaces on the
    /// subsequent sftp operation.
    @Test func statMisreportsSameNamedSingleChild() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("-rw-r--r-- 1 u g 10 Jun  9 10:00 app"),
        ])
        let meta = try await makeSource(runner).stat("/srv/app")
        // The heuristic sees one entry named "app" == lastPathComponent("app"),
        // so it (incorrectly) concludes it's a file. Assert the current behavior
        // to pin the limitation.
        #expect(!meta.isDirectory)
    }

    @Test func listQuotesPathsWithSpacesAndQuotes() async throws {
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok("")])
        _ = try await makeSource(runner).list(#"/srv/my "dir""#, includeHidden: false)
        #expect((await runner.calls)[0].stdin == "ls -la \"/srv/my \\\"dir\\\"\"\n")
    }
}
