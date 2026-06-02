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
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

@MainActor @Test func reorderBookmarksPersistsOrder() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.addBookmark(path: "/a")
    store.addBookmark(path: "/b")
    store.addBookmark(path: "/c")
    #expect(store.bookmarks().map(\.path) == ["/a", "/b", "/c"])

    store.reorderBookmarks(["/c", "/a", "/b"])
    #expect(store.bookmarks().map(\.path) == ["/c", "/a", "/b"])
}

@MainActor @Test func reorderFavoritesPersistsOrder() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.addFavorite(path: "/x.md", kind: .markdown)
    store.addFavorite(path: "/y.md", kind: .markdown)
    #expect(store.favorites().map(\.path) == ["/x.md", "/y.md"])

    store.reorderFavorites(["/y.md", "/x.md"])
    #expect(store.favorites().map(\.path) == ["/y.md", "/x.md"])
}

@MainActor @Test func displayNameStoresAndClears() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    #expect(store.displayName(for: "/p/.env") == nil)
    store.setMeta(path: "/p/.env", info: "", tagNames: ["prod"], displayName: "Chief — prod keys")
    #expect(store.displayName(for: "/p/.env") == "Chief — prod keys")
    #expect(store.meta(for: "/p/.env")?.tags.map(\.name) == ["prod"])

    // Clearing the name returns nil again (empty is treated as "no label").
    store.setMeta(path: "/p/.env", info: "", tagNames: ["prod"], displayName: "")
    #expect(store.displayName(for: "/p/.env") == nil)
}

@MainActor @Test func bookmarksAreIndependentOfFavorites() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    #expect(store.isBookmarked(path: "/work") == false)
    store.addBookmark(path: "/work")
    store.addBookmark(path: "/work")            // no duplicate
    #expect(store.bookmarks().map(\.path) == ["/work"])
    #expect(store.isBookmarked(path: "/work") == true)

    // A folder can be both bookmarked and favorited (separate models).
    store.addFavoriteFolder(path: "/work")
    #expect(store.isFavorite(path: "/work") == true)
    #expect(store.isBookmarked(path: "/work") == true)
    // favorites() does not leak bookmarks.
    #expect(store.favorites().allSatisfy { $0.kindRaw != "bookmark" })

    store.removeBookmark(path: "/work")
    #expect(store.isBookmarked(path: "/work") == false)
    #expect(store.isFavorite(path: "/work") == true)   // favorite survives
}

@MainActor @Test func favoriteFoldersAndIsFavorite() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    #expect(store.isFavorite(path: "/a") == false)
    store.addFavoriteFolder(path: "/a")
    store.addFavorite(path: "/a/b.md", kind: .markdown)

    #expect(store.isFavorite(path: "/a") == true)
    #expect(store.isFavorite(path: "/a/b.md") == true)
    // Folder favorites persist a "folder" sentinel kind.
    let folderFav = store.favorites().first { $0.path == "/a" }
    #expect(folderFav?.kindRaw == "folder")
    // Adding the same folder twice does not duplicate.
    store.addFavoriteFolder(path: "/a")
    #expect(store.favorites().filter { $0.path == "/a" }.count == 1)
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

@MainActor @Test func migrateBookmarksBecomeFolderFavorites() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.addBookmark(path: "/work")
    store.addBookmark(path: "/docs")
    store.addFavoriteFolder(path: "/work")   // already favorited too

    let migratedCount = store.migrateBookmarksToFavorites()

    // /docs was bookmark-only -> becomes a folder favorite; /work already was.
    #expect(migratedCount == 1)
    #expect(store.isFavorite(path: "/docs") == true)
    #expect(store.favorites().first { $0.path == "/docs" }?.kindRaw == "folder")
    // Bookmarks are cleared after migration so it never runs twice.
    #expect(store.bookmarks().isEmpty)
    // Running again is a no-op.
    #expect(store.migrateBookmarksToFavorites() == 0)
}

@MainActor @Test func pathsTaggedWithReturnsSet() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/a/c.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/a/d.md", info: "", tagNames: ["home"])

    #expect(store.paths(taggedWith: "work") == ["/a/b.md", "/a/c.md"])
    #expect(store.paths(taggedWith: "missing").isEmpty)
}
