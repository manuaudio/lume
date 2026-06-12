import Testing
import Foundation
@testable import LumeKit

struct GitHubConnectionStoreTests {
    @MainActor private func makeStore() -> ConnectionStore {
        ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubConnectionStoreTests-\(UUID().uuidString).json"))
    }

    @Test @MainActor func decodesLegacyJSONWithoutGitHubSection() throws {
        let legacy = #"{"manualHosts":[],"hostState":{"web1":{"recentFiles":["/etc/a.conf"]}}}"#
        let state = try JSONDecoder().decode(ConnectionStoreState.self, from: Data(legacy.utf8))
        #expect(state.githubRepos.isEmpty)
        #expect(state.hostState["web1"]?.recentFiles == ["/etc/a.conf"])
    }

    @Test @MainActor func recordsBranchPathAndRecents() {
        let store = makeStore()
        store.noteRepoConnected(slug: "o/r")
        store.noteRepoBranch(slug: "o/r", branch: "feature/x")
        store.noteRepoBrowsed(slug: "o/r", path: "/docs")
        store.noteRepoOpened(slug: "o/r", file: "/docs/a.md")
        store.noteRepoOpened(slug: "o/r", file: "/docs/b.md")
        store.noteRepoOpened(slug: "o/r", file: "/docs/a.md")   // re-open moves to front
        let repo = store.state.githubRepos["o/r"]
        #expect(repo?.lastBranch == "feature/x")
        #expect(repo?.lastPath == "/docs")
        #expect(repo?.recentFiles == ["/docs/a.md", "/docs/b.md"])
        #expect(repo?.lastUsed != nil)
    }

    @Test @MainActor func recentFilesAreCapped() {
        let store = makeStore()
        for i in 0..<12 { store.noteRepoOpened(slug: "o/r", file: "/f\(i).md") }
        #expect(store.state.githubRepos["o/r"]?.recentFiles.count == 8)
        #expect(store.state.githubRepos["o/r"]?.recentFiles.first == "/f11.md")
    }

    @Test @MainActor func recentReposOrderedByLastUsed() async throws {
        let store = makeStore()
        store.noteRepoConnected(slug: "o/first")
        // Sleep between connects: ordering compares Date() stamps, and
        // back-to-back calls could otherwise tie.
        try await Task.sleep(for: .milliseconds(2))
        store.noteRepoConnected(slug: "o/second")
        #expect(store.recentGitHubRepos == ["o/second", "o/first"])
        try await Task.sleep(for: .milliseconds(2))
        store.noteRepoConnected(slug: "o/first")   // reconnect bumps it to the front
        #expect(store.recentGitHubRepos == ["o/first", "o/second"])
    }

    @Test @MainActor func roundTripsThroughDisk() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubConnectionStoreTests-rt-\(UUID().uuidString).json")
        let store = ConnectionStore(fileURL: url)
        store.noteRepoBranch(slug: "o/r", branch: "main")
        let reloaded = ConnectionStore(fileURL: url)
        #expect(reloaded.state.githubRepos["o/r"]?.lastBranch == "main")
    }
}
