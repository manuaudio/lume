import Testing
import Foundation
@testable import LumeKit

@MainActor
struct FavoritesSyncEngineTests {
    private func makeEngine(store: FakeSyncDocumentStore, now: Date = Date(timeIntervalSince1970: 3_000))
        throws -> (engine: FavoritesSyncEngine, library: LibraryStore, connections: ConnectionStore, container: Any) {
        let (library, container) = try makeLibrary()
        let connections = ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString).json"))
        let engine = FavoritesSyncEngine(library: library, connections: connections,
                                         store: store, now: { now })
        return (engine, library, connections, container)
    }

    @Test func incomingRemoteFavoriteIsAppliedLocally() throws {
        let incoming = SyncDocument(remoteFavorites: [
            RemoteFavoriteRecord(ref: "ssh:web1:/a", sourceKind: "ssh", sourceKey: "web1",
                                 path: "/a", isDirectory: false,
                                 updatedAt: Date(timeIntervalSince1970: 2_000), deleted: false)
        ])
        let store = FakeSyncDocumentStore(shared: incoming)
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        engine.sync()
        #expect(library.isRemoteFavorite(ref: "ssh:web1:/a"))
    }

    @Test func localRemoteFavoriteIsPushedToShared() throws {
        let store = FakeSyncDocumentStore()
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        library.addRemoteFavorite(ref: "github:o/r:/x.md", sourceKind: "github",
                                  sourceKey: "o/r", path: "/x.md", isDirectory: false)
        engine.sync()
        #expect(store.shared.remoteFavorites.map(\.ref) == ["github:o/r:/x.md"])
        #expect(store.shared.remoteFavorites[0].updatedAt == Date(timeIntervalSince1970: 3_000))
    }

    @Test func incomingTombstoneRemovesLocalFavorite() throws {
        let store = FakeSyncDocumentStore()
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        library.addRemoteFavorite(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w",
                                  path: "/a", isDirectory: false)
        engine.sync()                                  // baseline now has it
        // Peer deletes it later:
        store.shared = SyncDocument(remoteFavorites: [
            RemoteFavoriteRecord(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w", path: "/a",
                                 isDirectory: false, updatedAt: Date(timeIntervalSince1970: 4_000), deleted: true)
        ])
        let later = FavoritesSyncEngine(library: library, connections: store2Connections(),
                                        store: store, now: { Date(timeIntervalSince1970: 5_000) })
        later.sync()
        #expect(library.isRemoteFavorite(ref: "ssh:w:/a") == false)
    }
    private func store2Connections() -> ConnectionStore {
        ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString).json"))
    }

    @Test func manualHostIdentityFileIsStoredTildeRelative() throws {
        let store = FakeSyncDocumentStore()
        let (engine, _, connections, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        let home = NSHomeDirectory()
        connections.addManualHost(SSHHost(alias: "h", hostname: "x", user: nil, port: nil,
                                          identityFile: "\(home)/.ssh/id_x"))
        engine.sync()
        #expect(store.shared.manualHosts.first?.identityFile == "~/.ssh/id_x")
    }

    @Test func appliedManualHostExpandsTilde() throws {
        let store = FakeSyncDocumentStore(shared: SyncDocument(manualHosts: [
            ManualHostRecord(alias: "h", hostname: "x", user: nil, port: nil,
                             identityFile: "~/.ssh/id_x",
                             updatedAt: Date(timeIntervalSince1970: 2_000), deleted: false)
        ]))
        let (engine, _, connections, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        engine.sync()
        let applied = connections.state.manualHosts.first
        #expect(applied?.identityFile == "\(NSHomeDirectory())/.ssh/id_x")
    }

    @Test func unavailableStoreSkipsSyncEntirely() throws {
        let store = FakeSyncDocumentStore(available: false)
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        library.addRemoteFavorite(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w",
                                  path: "/a", isDirectory: false)
        engine.sync()
        #expect(store.sharedWrites == 0)               // never wrote
    }

    @Test func onAppliedFiresWhenStoresChange() throws {
        let store = FakeSyncDocumentStore(shared: SyncDocument(remoteFavorites: [
            RemoteFavoriteRecord(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w", path: "/a",
                                 isDirectory: false, updatedAt: Date(timeIntervalSince1970: 2_000), deleted: false)
        ]))
        let (engine, _, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        var fired = 0
        engine.onApplied = { fired += 1 }
        engine.sync()
        #expect(fired == 1)
    }
}
