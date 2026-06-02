import Testing
import SwiftData
@testable import LumeCore

// NOTE: `makeStore()` returns the `ModelContainer` alongside the store, and each
// test retains it for its whole body. `LibraryStore` only holds a `ModelContext`,
// and on this toolchain (Apple Swift 6.3.2, macOS 26 SDK) a `ModelContext` whose
// owning in-memory `ModelContainer` has been deallocated crashes with SIGTRAP on
// the next SwiftData operation. In the real app the container is owned by the
// SwiftUI `.modelContainer` scene for the app's lifetime, so this only affects
// the test helper — hence the lifetime is pinned here rather than changing the
// `LibraryStore(context:)` public API.
@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

@MainActor @Test func addAndRemoveFavorite() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.addFavorite(path: "/a/b.md", kind: .markdown)
    #expect(store.favorites().map(\.path) == ["/a/b.md"])

    // Adding the same path twice does not duplicate.
    store.addFavorite(path: "/a/b.md", kind: .markdown)
    #expect(store.favorites().count == 1)

    store.removeFavorite(path: "/a/b.md")
    #expect(store.favorites().isEmpty)
}

@MainActor @Test func setMetaUpsertsAndTagsAreReused() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a/b.md", info: "draft", tagNames: ["work", "draft"])
    store.setMeta(path: "/a/c.md", info: "", tagNames: ["work"])

    #expect(store.meta(for: "/a/b.md")?.info == "draft")
    #expect(Set(store.meta(for: "/a/b.md")?.tags.map(\.name) ?? []) == ["work", "draft"])

    // "work" tag is shared, not duplicated.
    let workFiles = store.files(taggedWith: "work").map(\.path).sorted()
    #expect(workFiles == ["/a/b.md", "/a/c.md"])
}

@MainActor @Test func setMetaReplacesTagsOnUpdate() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/a/b.md", info: "updated", tagNames: ["personal"])

    #expect(store.meta(for: "/a/b.md")?.info == "updated")
    #expect(store.meta(for: "/a/b.md")?.tags.map(\.name) == ["personal"])
    #expect(store.files(taggedWith: "work").isEmpty)
}
