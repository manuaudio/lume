import Foundation
@testable import LumeKit

/// In-memory `SyncDocumentStore` for engine tests: holds the shared doc and
/// baseline as plain values and records writes for assertions.
final class FakeSyncDocumentStore: SyncDocumentStore, @unchecked Sendable {
    var available: Bool
    var shared: SyncDocument
    var baseline = SyncDocument()
    private(set) var sharedWrites = 0

    init(available: Bool = true, shared: SyncDocument = SyncDocument()) {
        self.available = available
        self.shared = shared
    }

    var isAvailable: Bool { available }
    func readShared() throws -> SyncDocument { shared }
    func writeShared(_ doc: SyncDocument) throws { shared = doc; sharedWrites += 1 }
    func readBaseline() -> SyncDocument { baseline }
    func writeBaseline(_ doc: SyncDocument) { baseline = doc }
}
