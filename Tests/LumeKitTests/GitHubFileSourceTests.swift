import Testing
import Foundation
@testable import LumeKit

struct GitHubFileSourceTests {
    private func makeSource(_ runner: FakeCommandRunner) -> GitHubFileSource {
        GitHubFileSource(slug: "o/r", client: GitHubClient(runner: runner, ghPath: "/fake/gh"))
    }

    private static func contentsJSON(_ text: String, sha: String) -> String {
        #"{"content":"\#(Data(text.utf8).base64EncodedString())","encoding":"base64","sha":"\#(sha)"}"#
    }

    @Test func listFiltersSortsSkipsSubmodulesAndBuildsRefs() async throws {
        let listing = #"""
        [{"name":"zeta.md","path":"zeta.md","sha":"1","size":5,"type":"file"},
         {"name":"docs","path":"docs","sha":"2","size":0,"type":"dir"},
         {"name":".git","path":".git","sha":"3","size":0,"type":"dir"},
         {"name":".secret","path":".secret","sha":"4","size":1,"type":"file"},
         {"name":".env","path":".env","sha":"5","size":1,"type":"file"},
         {"name":"vendored","path":"vendored","sha":"6","size":0,"type":"submodule"},
         {"name":"link.md","path":"link.md","sha":"7","size":1,"type":"symlink"}]
        """#
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let source = makeSource(runner)
        await source.setBranch("main")
        let nodes = try await source.list("/", includeHidden: false)
        // .git ignored always; .secret hidden; submodule skipped; folders first; .env visible.
        #expect(nodes.map(\.name) == ["docs", ".env", "link.md", "zeta.md"])
        #expect(nodes[0].isDirectory)
        #expect(nodes[2].isSymlink)
        #expect(nodes[1].ref == ResourceRef(sourceID: .github(slug: "o/r"), path: "/.env"))
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r/contents?ref=main"])
    }

    @Test func listOfSubdirectoryBuildsNestedPaths() async throws {
        let listing = #"[{"name":"a.md","path":"docs/a.md","sha":"1","size":1,"type":"file"}]"#
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let source = makeSource(runner)
        await source.setBranch("main")
        let nodes = try await source.list("/docs", includeHidden: false)
        #expect(nodes[0].ref.path == "/docs/a.md")
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r/contents/docs?ref=main"])
    }

    @Test func readCachesShaAndWriteSendsIt() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(Self.contentsJSON("hello", sha: "old1")),
            FakeCommandRunner.ok(#"{"content":{"sha":"new1"}}"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        let text = try await source.read("/docs/a.md")
        #expect(text == "hello")
        try await source.write("hello edited", to: "/docs/a.md")
        let put = await runner.calls[1]
        #expect(put.arguments == ["api", "repos/o/r/contents/docs/a.md", "--method", "PUT", "--input", "-"])
        let stdin = put.stdin ?? ""
        #expect(stdin.contains(#""sha":"old1""#))
        #expect(stdin.contains(#""branch":"main""#))
        #expect(stdin.contains(#""message":"Update docs\/a.md""#))
    }

    @Test func successfulWriteUpdatesShaForConsecutiveSaves() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(Self.contentsJSON("v1", sha: "s1")),
            FakeCommandRunner.ok(#"{"content":{"sha":"s2"}}"#),
            FakeCommandRunner.ok(#"{"content":{"sha":"s3"}}"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        _ = try await source.read("/a.md")
        try await source.write("v2", to: "/a.md")
        try await source.write("v3", to: "/a.md")
        #expect(await runner.calls[2].stdin?.contains(#""sha":"s2""#) == true)
    }

    @Test func writeWithoutPriorReadFailsClean() async {
        let source = makeSource(FakeCommandRunner())
        await source.setBranch("main")
        await #expect(throws: GitHubError.self) {
            try await source.write("text", to: "/never-read.md")
        }
    }

    @Test func setBranchClearsShaCache() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(Self.contentsJSON("v1", sha: "s1")),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        _ = try await source.read("/a.md")
        await source.setBranch("feature/x")
        await #expect(throws: GitHubError.self) {
            try await source.write("v2", to: "/a.md")   // stale sha was dropped
        }
        #expect(await runner.calls.count == 1)                // no PUT was attempted
    }

    @Test func nonUTF8ContentThrowsNotUTF8() async {
        let binary = Data([0xFF, 0xFE, 0x00]).base64EncodedString()
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":"\#(binary)","encoding":"base64","sha":"b1"}"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        await #expect(throws: GitHubError.notUTF8(path: "/img.png")) {
            _ = try await source.read("/img.png")
        }
    }

    @Test func statRoutesThroughClient() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"name":"a","path":"d/a","sha":"s","size":1,"type":"file"}]"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        let meta = try await source.stat("/d")
        #expect(meta.isDirectory)
        #expect(await runner.calls[0].arguments == ["api", "repos/o/r/contents/d?ref=main"])
    }
}
