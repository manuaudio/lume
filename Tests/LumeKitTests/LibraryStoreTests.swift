import Testing
import SwiftData
@testable import LumeKit

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

@MainActor @Test func migrateAssignsDistinctSortIndexes() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.addBookmark(path: "/a")
    store.addBookmark(path: "/b")
    store.migrateBookmarksToFavorites()

    let favs = store.favorites().filter { $0.path == "/a" || $0.path == "/b" }
        .sorted { $0.sortIndex < $1.sortIndex }
    #expect(Set(favs.map(\.sortIndex)).count == 2)          // distinct
    #expect(favs.map(\.path) == ["/a", "/b"])               // stable order
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

@MainActor @Test func hideSetsFlagAndHiddenPathsReflectsIt() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    #expect(store.hiddenPaths().isEmpty)

    store.setHidden(true, paths: ["/p/a.txt", "/p/b.txt"])
    #expect(store.hiddenPaths() == ["/p/a.txt", "/p/b.txt"])
    #expect(store.meta(for: "/p/a.txt")?.hidden == true)

    // Un-hiding one path removes only that path from the set.
    store.setHidden(false, paths: ["/p/a.txt"])
    #expect(store.hiddenPaths() == ["/p/b.txt"])
    #expect(store.meta(for: "/p/a.txt")?.hidden == false)
}

@MainActor @Test func hidePreservesExistingMeta() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/p/c.txt", info: "note", tagNames: ["work"], displayName: "C")
    store.setHidden(true, paths: ["/p/c.txt"])

    let m = store.meta(for: "/p/c.txt")
    #expect(m?.hidden == true)
    #expect(m?.info == "note")
    #expect(m?.displayName == "C")
    #expect(m?.tags.map(\.name) == ["work"])
}

// MARK: - Tag / GROUP management (Increment 4)

@MainActor @Test func createEmptyTagPersistsAndIsIdempotent() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "Spec")
    #expect(store.allTags().map(\.name) == ["Spec"])
    // Empty groups are valid and not auto-pruned; idempotent by name; blanks ignored.
    store.createEmptyTag(named: "Spec")
    store.createEmptyTag(named: "   ")
    #expect(store.allTags().map(\.name) == ["Spec"])
    #expect(store.paths(taggedWith: "Spec").isEmpty)
}

@MainActor @Test func removeTagFromFileKeepsEmptyGroup() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["solo"])
    store.removeTag(named: "solo", fromPath: "/a.md")
    #expect(store.paths(taggedWith: "solo").isEmpty)
    // The group itself persists even when emptied (GROUPS design).
    #expect(store.allTags().map(\.name) == ["solo"])
}

@MainActor @Test func renameTagWithoutClash() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["old"])
    #expect(store.renameTag(named: "old", to: "new"))
    #expect(store.allTags().map(\.name) == ["new"])
    #expect(store.paths(taggedWith: "new") == ["/a.md"])
    // Renaming a missing tag, to blank, or to the same name all fail.
    #expect(store.renameTag(named: "ghost", to: "x") == false)
    #expect(store.renameTag(named: "new", to: "  ") == false)
    #expect(store.renameTag(named: "new", to: "new") == false)
}

@MainActor @Test func renameTagMergesOnNameClash() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["src"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["dst"])
    #expect(store.renameTag(named: "src", to: "dst"))
    #expect(store.allTags().map(\.name) == ["dst"])
    #expect(store.paths(taggedWith: "dst") == ["/a.md", "/b.md"])
}

@MainActor @Test func deleteTagDetachesFromFiles() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["gone", "keep"])
    store.deleteTag(named: "gone")
    #expect(store.allTags().map(\.name) == ["keep"])
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["keep"])
}

@MainActor @Test func recolorTagWrapsOutOfRange() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "c")
    store.recolorTag(named: "c", colorIndex: 5)
    #expect(store.colorIndex(forTagNamed: "c") == 5)
    // Out-of-range index wraps into the palette (never crashes).
    store.recolorTag(named: "c", colorIndex: TagPalette.count + 2)
    #expect(store.colorIndex(forTagNamed: "c") == TagPalette.wrap(TagPalette.count + 2))
}

@MainActor @Test func pruneOrphanTagsRemovesOnlyEmptyOnes() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "empty")
    store.setMeta(path: "/a", info: "", tagNames: ["used"])
    #expect(store.pruneOrphanTags() == 1)
    #expect(store.allTags().map(\.name) == ["used"])
}

@MainActor @Test func mergeTagsFoldsFilesAndAppliesColor() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a", info: "", tagNames: ["one"])
    store.setMeta(path: "/b", info: "", tagNames: ["two"])
    store.setMeta(path: "/c", info: "", tagNames: ["three"])
    #expect(store.mergeTags(["one", "two", "three"], into: "all", colorIndex: 3))
    #expect(store.allTags().map(\.name) == ["all"])
    #expect(store.paths(taggedWith: "all") == ["/a", "/b", "/c"])
    #expect(store.colorIndex(forTagNamed: "all") == 3)
}

@MainActor @Test func taggedWithAllAndAny() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a", info: "", tagNames: ["x", "y"])
    store.setMeta(path: "/b", info: "", tagNames: ["x"])
    #expect(store.paths(taggedWithAll: ["x", "y"]) == ["/a"])
    #expect(store.paths(taggedWithAny: ["x", "y"]) == ["/a", "/b"])
    #expect(store.paths(taggedWithAll: []).isEmpty)
    #expect(store.paths(taggedWithAny: []).isEmpty)
}
