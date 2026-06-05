import Testing
import SwiftData
@testable import LibraryKit

// Retain the in-memory container for the whole test body (SIGTRAP otherwise on
// this toolchain). Same pattern as LibraryStoreTests / TagStoreTests.
@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

@MainActor @Test func createEmptyTagCreatesAPersistentEmptyTag() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "project-x")
    #expect(store.allTags().map(\.name) == ["project-x"])
    #expect(store.files(taggedWith: "project-x").isEmpty)
    // It gets a cycling palette color like any new tag (first tag → index 0).
    #expect(store.colorIndex(forTagNamed: "project-x") == 0)
}

@MainActor @Test func createEmptyTagIsIdempotentByName() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "dup")
    store.createEmptyTag(named: "dup")   // no second tag, name is unique
    #expect(store.allTags().filter { $0.name == "dup" }.count == 1)
}

@MainActor @Test func createEmptyTagTrimsAndRejectsBlank() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "   spaced   ")
    store.createEmptyTag(named: "    ")     // blank → ignored
    #expect(store.allTags().map(\.name) == ["spaced"])
}
