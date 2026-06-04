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

@MainActor @Test func recolorTagPersistsAndWraps() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    store.recolorTag(named: "work", colorIndex: 5)
    #expect(store.colorIndex(forTagNamed: "work") == 5)
    store.recolorTag(named: "work", colorIndex: 9)
    #expect(store.colorIndex(forTagNamed: "work") == 1)
    store.recolorTag(named: "ghost", colorIndex: 3)
    #expect(store.colorIndex(forTagNamed: "ghost") == 0)
}

@MainActor @Test func deleteTagRemovesItFromAllFiles() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work", "keep"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["work"])
    store.deleteTag(named: "work")
    #expect(store.files(taggedWith: "work").isEmpty)
    #expect(store.allTags().map(\.name) == ["keep"])
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["keep"])
    #expect(store.meta(for: "/b.md")?.tags.isEmpty == true)
}

@MainActor @Test func pruneOrphanTagsDeletesUnreferencedTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["orphan", "kept"])
    if let m = store.meta(for: "/a.md") {
        m.tags = m.tags.filter { $0.name == "kept" }
    }
    let removed = store.pruneOrphanTags()
    #expect(removed == 1)
    #expect(store.allTags().map(\.name) == ["kept"])
}

@MainActor @Test func renameTagToNewNameJustRenames() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    let ok = store.renameTag(named: "wip", to: "in-progress")
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["in-progress"])
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["in-progress"])
}

@MainActor @Test func renameTagIntoExistingNameMerges() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["wip", "work"])
    let ok = store.renameTag(named: "wip", to: "work")
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["work"])
    #expect(store.paths(taggedWith: "work") == ["/a.md", "/b.md", "/c.md"])
    #expect(store.meta(for: "/c.md")?.tags.map(\.name) == ["work"])
}

@MainActor @Test func renameTagRejectsBlankOrUnchangedOrMissing() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.renameTag(named: "work", to: "   ") == false)
    #expect(store.renameTag(named: "work", to: "work") == false)
    #expect(store.renameTag(named: "ghost", to: "x") == false)
    #expect(store.allTags().map(\.name) == ["work"])
}
