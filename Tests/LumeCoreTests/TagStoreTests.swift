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
