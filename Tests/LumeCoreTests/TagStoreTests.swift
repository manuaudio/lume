import Testing
import SwiftData
@testable import LumeCore

@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

@MainActor @Test func newTagDefaultsToColorIndexZero() throws {
    let (_, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    let t = Tag(name: "solo")
    #expect(t.colorIndex == 0)
}

@MainActor @Test func tagsGetCyclingColorsOnCreation() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["first"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["second"])
    #expect(store.colorIndex(forTagNamed: "first") == 0)
    #expect(store.colorIndex(forTagNamed: "second") == 1)
    #expect(store.colorIndex(forTagNamed: "missing") == 0)
}

@MainActor @Test func allTagsReturnsEveryTagSorted() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["zebra"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["apple"])
    #expect(store.allTags().map(\.name) == ["apple", "zebra"])
}
