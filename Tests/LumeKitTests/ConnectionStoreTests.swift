import Testing
import Foundation
@testable import LumeKit

@MainActor
struct ConnectionStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStoreTests-\(UUID().uuidString).json")
    }

    @Test func manualHostsPersistAcrossReload() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        store.addManualHost(SSHHost(alias: "prod", hostname: "10.0.0.5", user: "deploy"))
        let reloaded = ConnectionStore(fileURL: url)
        #expect(reloaded.state.manualHosts.map(\.alias) == ["prod"])
        #expect(reloaded.state.manualHosts[0].user == "deploy")
    }

    @Test func addingSameAliasReplaces() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        store.addManualHost(SSHHost(alias: "prod", hostname: "old"))
        store.addManualHost(SSHHost(alias: "prod", hostname: "new"))
        #expect(store.state.manualHosts.count == 1)
        #expect(store.state.manualHosts[0].hostname == "new")
    }

    @Test func recentFilesAreMRUCappedAtEight() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        for i in 1...10 { store.noteOpened(alias: "web1", file: "/etc/f\(i)") }
        store.noteOpened(alias: "web1", file: "/etc/f3")   // re-open → moves to front
        let recents = store.state.hostState["web1"]?.recentFiles ?? []
        #expect(recents.count == 8)
        #expect(recents.first == "/etc/f3")
        #expect(!recents.contains("/etc/f1"))               // pushed out by the cap
    }

    @Test func lastPathAndRemoveHost() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        store.noteBrowsed(alias: "web1", path: "/srv/app")
        #expect(store.state.hostState["web1"]?.lastPath == "/srv/app")
        store.removeManualHost(alias: "web1")
        #expect(store.state.hostState["web1"] == nil)
    }

    @Test func corruptFileFallsBackToEmptyState() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json{{{".utf8).write(to: url)
        let store = ConnectionStore(fileURL: url)
        #expect(store.state == ConnectionStoreState())
    }
}
