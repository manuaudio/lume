import Testing
import Foundation
@testable import LumeKit

struct UbiquityDocumentStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString).json")
    }
    private func sampleFav() -> RemoteFavoriteRecord {
        RemoteFavoriteRecord(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w", path: "/a",
                             isDirectory: false, updatedAt: Date(timeIntervalSince1970: 1), deleted: false)
    }

    @Test func sharedDocumentRoundTrips() throws {
        let shared = tempURL(), baseline = tempURL()
        defer { try? FileManager.default.removeItem(at: shared) }
        let store = UbiquityDocumentStore(sharedURL: shared, baselineURL: baseline)
        #expect(store.isAvailable)
        try store.writeShared(SyncDocument(remoteFavorites: [sampleFav()]))
        let back = try store.readShared()
        #expect(back.remoteFavorites.map(\.ref) == ["ssh:w:/a"])
    }

    @Test func missingSharedReadsEmpty() throws {
        let store = UbiquityDocumentStore(sharedURL: tempURL(), baselineURL: tempURL())
        #expect(try store.readShared() == SyncDocument())   // absent file → empty doc
    }

    @Test func corruptSharedReadsEmpty() throws {
        let shared = tempURL(), baseline = tempURL()
        defer { try? FileManager.default.removeItem(at: shared) }
        try Data("not json".utf8).write(to: shared)
        let store = UbiquityDocumentStore(sharedURL: shared, baselineURL: baseline)
        #expect(try store.readShared() == SyncDocument())   // unreadable → empty, never throws
    }

    @Test func baselineRoundTrips() {
        let baseline = tempURL()
        defer { try? FileManager.default.removeItem(at: baseline) }
        let store = UbiquityDocumentStore(sharedURL: tempURL(), baselineURL: baseline)
        #expect(store.readBaseline() == SyncDocument())     // none yet
        store.writeBaseline(SyncDocument(remoteFavorites: [sampleFav()]))
        #expect(store.readBaseline().remoteFavorites.map(\.ref) == ["ssh:w:/a"])
    }

    @Test func nilSharedMeansUnavailableAndNoOp() throws {
        let store = UbiquityDocumentStore(sharedURL: nil, baselineURL: tempURL())
        #expect(store.isAvailable == false)
        try store.writeShared(SyncDocument(remoteFavorites: [sampleFav()]))  // no-op, no throw
        #expect(try store.readShared() == SyncDocument())
    }
}
