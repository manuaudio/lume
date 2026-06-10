import Foundation
import Testing
import SwiftData
@testable import LumeKit

@MainActor
private func tempStoreDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lume-factory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor @Test func freshStoreOpensHealthy() throws {
    let dir = try tempStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = LibraryContainerFactory.make(at: dir.appendingPathComponent("library.store"))
    defer { withExtendedLifetime(result.container) {} }
    #expect(result.health == .healthy)

    let store = LibraryStore(context: result.container.mainContext)
    store.createEmptyTag(named: "t")
    #expect(store.allTags().map(\.name) == ["t"])
    #expect(store.lastPersistenceError == nil)
}

@MainActor @Test func corruptStoreIsMovedAsideAndReplaced() throws {
    let dir = try tempStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let storeURL = dir.appendingPathComponent("library.store")
    let garbage = Data("definitely not a sqlite database".utf8)
    try garbage.write(to: storeURL)

    let result = LibraryContainerFactory.make(at: storeURL)
    defer { withExtendedLifetime(result.container) {} }

    guard case .recoveredFromCorruption(let backupURL) = result.health else {
        Issue.record("expected .recoveredFromCorruption, got \(result.health)")
        return
    }
    // The corrupt bytes were preserved, not destroyed.
    let backup = try #require(backupURL)
    #expect(try Data(contentsOf: backup) == garbage)
    #expect(backup.lastPathComponent.contains("corrupt-"))

    // The replacement container actually persists.
    let store = LibraryStore(context: result.container.mainContext)
    store.createEmptyTag(named: "fresh")
    #expect(store.allTags().map(\.name) == ["fresh"])
    #expect(store.lastPersistenceError == nil)
}
