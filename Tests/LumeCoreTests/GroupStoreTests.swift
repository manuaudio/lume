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

@MainActor @Test func removeTagFromPathLeavesOtherTagsIntact() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["alpha", "beta"])
    store.removeTag(named: "alpha", fromPath: "/a.md")

    // The file keeps "beta"; only "alpha" was removed from it.
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["beta"])
    // "alpha" no longer carries this file.
    #expect(store.files(taggedWith: "alpha").isEmpty)
}

@MainActor @Test func removeTagDoesNotPruneTheNowEmptyGroup() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["solo"])
    store.removeTag(named: "solo", fromPath: "/a.md")

    // The tag is now empty but MUST persist (empty groups are valid).
    #expect(store.allTags().map(\.name) == ["solo"])
    #expect(store.files(taggedWith: "solo").isEmpty)
}

@MainActor @Test func removeTagIsSafeForUnknownTagOrPath() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["x"])
    store.removeTag(named: "ghost", fromPath: "/a.md")  // unknown tag
    store.removeTag(named: "x", fromPath: "/missing.md") // unknown path
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["x"])
}
