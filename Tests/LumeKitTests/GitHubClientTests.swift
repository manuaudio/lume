import Testing
import Foundation
@testable import LumeKit

struct GitHubClientTests {
    private func makeClient(_ runner: FakeCommandRunner) -> GitHubClient {
        GitHubClient(runner: runner, ghPath: "/fake/gh")
    }

    @Test func missingGhThrowsBeforeRunningAnything() async {
        let runner = FakeCommandRunner()
        let client = GitHubClient(runner: runner, ghPath: nil)
        await #expect(throws: GitHubError.ghNotInstalled) {
            try await client.checkAuth()
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func checkAuthPassesAndFails() async throws {
        let ok = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        try await makeClient(ok).checkAuth()
        #expect(await ok.calls[0].executable == "/fake/gh")
        #expect(await ok.calls[0].arguments == ["auth", "status"])

        let bad = FakeCommandRunner(results: [FakeCommandRunner.fail("You are not logged into any GitHub hosts.")])
        await #expect(throws: GitHubError.notAuthenticated) {
            try await makeClient(bad).checkAuth()
        }
    }

    @Test func repoInfoParsesDefaultBranchAndPush() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"default_branch":"main","permissions":{"push":true,"pull":true}}"#),
        ])
        let info = try await makeClient(runner).repoInfo(slug: "o/r")
        #expect(info == GitHubRepoInfo(defaultBranch: "main", canPush: true))
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r"])
    }

    @Test func repoInfoWithoutPermissionsMeansNoPush() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"default_branch":"master"}"#),
        ])
        let info = try await makeClient(runner).repoInfo(slug: "o/r")
        #expect(info == GitHubRepoInfo(defaultBranch: "master", canPush: false))
    }

    @Test func listDirectoryBuildsEndpointAndParses() async throws {
        let listing = #"""
        [{"name":"docs","path":"docs","sha":"d1","size":0,"type":"dir"},
         {"name":"setup.md","path":"docs/setup.md","sha":"f1","size":12,"type":"file"}]
        """#
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let entries = try await makeClient(runner).listDirectory(slug: "o/r", path: "docs", ref: "main")
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r/contents/docs?ref=main"])
        #expect(entries == [
            GitHubDirEntry(name: "docs", type: "dir", size: 0, sha: "d1"),
            GitHubDirEntry(name: "setup.md", type: "file", size: 12, sha: "f1"),
        ])
    }

    @Test func listDirectoryRootAndPathEncoding() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("[]"), FakeCommandRunner.ok("[]"),
        ])
        let client = makeClient(runner)
        _ = try await client.listDirectory(slug: "o/r", path: "", ref: nil)
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r/contents"])
        _ = try await client.listDirectory(slug: "o/r", path: "my docs/sub", ref: "feature/x")
        #expect(await runner.calls[1].arguments == ["api", "repos/o/r/contents/my%20docs/sub?ref=feature/x"])
    }

    @Test func readFileDecodesBase64AndKeepsSha() async throws {
        let b64 = Data("hello".utf8).base64EncodedString()
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":"\#(b64)\n","encoding":"base64","sha":"abc","size":5}"#),
        ])
        let file = try await makeClient(runner).readFile(slug: "o/r", path: "a.md", ref: "main")
        #expect(file == GitHubRemoteFile(data: Data("hello".utf8), sha: "abc"))
    }

    @Test func readFileFallsBackToBlobForLargeFiles() async throws {
        // Contents API truncates >1 MB: content empty, encoding "none".
        let b64 = Data("big".utf8).base64EncodedString()
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":"","encoding":"none","sha":"bigsha","size":2000000}"#),
            FakeCommandRunner.ok(#"{"content":"\#(b64)","encoding":"base64"}"#),
        ])
        let file = try await makeClient(runner).readFile(slug: "o/r", path: "big.md", ref: nil)
        #expect(file.data == Data("big".utf8))
        #expect(file.sha == "bigsha")
        #expect(await runner.calls[1].arguments == ["api", "repos/o/r/git/blobs/bigsha"])
    }

    @Test func writeFilePutsJSONBodyOverStdinAndReturnsNewSha() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":{"sha":"new1"},"commit":{"sha":"c1"}}"#),
        ])
        let newSha = try await makeClient(runner).writeFile(
            slug: "o/r", path: "docs/a.md", content: Data("hi".utf8),
            message: "Update docs/a.md", sha: "old1", branch: "main")
        #expect(newSha == "new1")
        let call = await runner.calls[0]
        #expect(call.arguments == ["api", "repos/o/r/contents/docs/a.md", "--method", "PUT", "--input", "-"])
        // sortedKeys encoding makes the body deterministic:
        let expectedBody = #"{"branch":"main","content":"\#(Data("hi".utf8).base64EncodedString())","message":"Update docs\/a.md","sha":"old1"}"#
        #expect(call.stdin == expectedBody)
    }

    @Test func listBranchesParsesNames() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"name":"main"},{"name":"feature/x"}]"#),
        ])
        let branches = try await makeClient(runner).listBranches(slug: "o/r")
        #expect(branches == ["main", "feature/x"])
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r/branches?per_page=100"])
    }

    @Test func listUserReposUsesRepoListJSON() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"nameWithOwner":"o/r","isPrivate":true}]"#),
        ])
        let repos = try await makeClient(runner).listUserRepos()
        #expect(repos == [GitHubRepoSummary(slug: "o/r", isPrivate: true)])
        #expect(await runner.calls[0].arguments
                == ["repo", "list", "--limit", "200", "--json", "nameWithOwner,isPrivate"])
    }

    @Test func statDistinguishesDirectoryFromFile() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"name":"a","path":"d/a","sha":"s","size":1,"type":"file"}]"#),
            FakeCommandRunner.ok(#"{"name":"a.md","sha":"s2","size":42,"type":"file","content":"","encoding":"base64"}"#),
        ])
        let client = makeClient(runner)
        let dir = try await client.stat(slug: "o/r", path: "d", ref: "main")
        #expect(dir.isDirectory)
        let file = try await client.stat(slug: "o/r", path: "a.md", ref: "main")
        #expect(!file.isDirectory)
        #expect(file.size == 42)
    }

    @Test func apiFailureMapsThroughGitHubError() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("gh: Not Found (HTTP 404)"),
        ])
        await #expect(throws: GitHubError.repoNotFound) {
            _ = try await makeClient(runner).repoInfo(slug: "o/missing")
        }
    }
}
