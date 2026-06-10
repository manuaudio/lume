import Foundation
import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func successfulSavesLeaveNoPersistenceError() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.addFavorite(path: "/a.md", kind: .markdown)
    store.createEmptyTag(named: "t")
    store.setMeta(path: "/a.md", info: "n", tagNames: ["t"])
    #expect(store.lastPersistenceError == nil)
}

@MainActor @Test func failedSaveSetsAndClearsLastPersistenceError() throws {
    // `allowsSave: false` + in-memory fails at CONTAINER CREATION on this
    // toolchain (the /dev/null-backed SQLite store can't be opened read-only,
    // NSCocoaErrorDomain 257), so per the plan's fallback we use a read-only
    // ON-DISK store: seed a valid store file, then reopen it with
    // `allowsSave: false` so `context.save()` throws deterministically.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumePersistenceErrorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("store.sqlite")

    do {  // Seed a valid store file, then release the container.
        let seed = try ModelContainer(
            for: Schema(versionedSchema: LumeSchemaV1.self),
            configurations: [ModelConfiguration(url: url)]
        )
        withExtendedLifetime(seed) {}
    }

    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV1.self),
        configurations: [ModelConfiguration(url: url, allowsSave: false)]
    )
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)

    store.createEmptyTag(named: "doomed")
    let failure = try #require(store.lastPersistenceError)
    #expect(failure.operation == "createEmptyTag")
    #expect(!failure.message.isEmpty)

    store.clearPersistenceError()
    #expect(store.lastPersistenceError == nil)
}
