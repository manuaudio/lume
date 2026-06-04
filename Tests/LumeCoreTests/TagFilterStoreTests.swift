import Testing
import SwiftData
@testable import LibraryKit

// Retain the `ModelContainer` for the whole test body: `LibraryStore` holds only
// a `ModelContext`, and on this toolchain a context whose in-memory container has
// deallocated crashes (SIGTRAP) on the next SwiftData op. Same pattern as
// TagStoreTests / LibraryStoreTests.
@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

// MARK: paths(taggedWithAll:) — intersection

@MainActor @Test func pathsTaggedWithAllIsIntersection() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work", "prod"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["work", "prod", "review"])
    #expect(store.paths(taggedWithAll: ["work", "prod"]) == ["/a.md", "/c.md"])
    #expect(store.paths(taggedWithAll: ["work"]) == ["/a.md", "/b.md", "/c.md"])
    #expect(store.paths(taggedWithAll: ["work", "prod", "review"]) == ["/c.md"])
}

@MainActor @Test func pathsTaggedWithAllEmptyInputIsEmpty() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.paths(taggedWithAll: []) == [])
}

@MainActor @Test func pathsTaggedWithAllWithMissingTagIsEmpty() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    // A name no file carries empties the intersection.
    #expect(store.paths(taggedWithAll: ["work", "ghost"]) == [])
}

// MARK: paths(taggedWithAny:) — union

@MainActor @Test func pathsTaggedWithAnyIsUnion() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["prod"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["review"])
    #expect(store.paths(taggedWithAny: ["work", "prod"]) == ["/a.md", "/b.md"])
    #expect(store.paths(taggedWithAny: ["work", "prod", "review"]) == ["/a.md", "/b.md", "/c.md"])
}

@MainActor @Test func pathsTaggedWithAnyEmptyInputIsEmpty() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.paths(taggedWithAny: []) == [])
}

@MainActor @Test func pathsTaggedWithAnyIgnoresMissingTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.paths(taggedWithAny: ["work", "ghost"]) == ["/a.md"])
}

// MARK: mergeTags(_:into:colorIndex:)

@MainActor @Test func mergeTagsConsolidatesFilesOntoSurvivor() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["wip", "draft", "keep"])
    let ok = store.mergeTags(["wip", "draft"], into: "wip", colorIndex: nil)
    #expect(ok == true)
    // "draft" is gone, "wip" carries every file that had wip OR draft.
    #expect(store.allTags().map(\.name).sorted() == ["keep", "wip"])
    #expect(store.paths(taggedWith: "wip") == ["/a.md", "/b.md", "/c.md"])
    // De-duped: /c.md had both, ends with a single wip (+ keep).
    #expect(store.meta(for: "/c.md")?.tags.map(\.name).sorted() == ["keep", "wip"])
}

@MainActor @Test func mergeTagsAppliesChosenColor() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    let ok = store.mergeTags(["wip", "draft"], into: "wip", colorIndex: 5)
    #expect(ok == true)
    #expect(store.colorIndex(forTagNamed: "wip") == 5)
}

@MainActor @Test func mergeTagsIntoBrandNewSurvivorName() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    // Survivor name isn't an existing tag — first source is renamed to it.
    let ok = store.mergeTags(["wip", "draft"], into: "status", colorIndex: 3)
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["status"])
    #expect(store.paths(taggedWith: "status") == ["/a.md", "/b.md"])
    #expect(store.colorIndex(forTagNamed: "status") == 3)
}

@MainActor @Test func mergeTagsSkipsSurvivorAsSourceAndUnknowns() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    // "wip" appears as both survivor and source (skip-self); "ghost" is unknown.
    let ok = store.mergeTags(["wip", "draft", "ghost"], into: "wip", colorIndex: nil)
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["wip"])
    #expect(store.paths(taggedWith: "wip") == ["/a.md", "/b.md"])
}

@MainActor @Test func mergeTagsPrunesEmptiedTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    _ = store.mergeTags(["wip", "draft"], into: "wip", colorIndex: nil)
    // No orphan "draft" tag lingers in the sidebar vocabulary.
    #expect(store.files(taggedWith: "draft").isEmpty)
    #expect(store.allTags().contains { $0.name == "draft" } == false)
}
