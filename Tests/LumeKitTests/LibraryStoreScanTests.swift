import Testing
import SwiftData
@testable import LumeKit

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self, Scan.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

@MainActor @Test func scanModelPersistsFields() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext

    let scan = Scan(name: "CLAUDE rules", patterns: ["CLAUDE.md", "*.env"], roots: ["/Users/me/Dev"])
    context.insert(scan)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<Scan>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.name == "CLAUDE rules")
    #expect(fetched.first?.patterns == ["CLAUDE.md", "*.env"])
    #expect(fetched.first?.roots == ["/Users/me/Dev"])
}

@MainActor @Test func scanCRUDViaStore() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)

    let a = store.addScan(name: "A", patterns: ["CLAUDE.md"], roots: ["/x"])
    let b = store.addScan(name: "B", patterns: ["*.env"], roots: ["/y"])
    #expect(store.scans().map(\.name) == ["A", "B"])
    #expect(b.sortIndex == 1)

    store.updateScan(a, name: "A2", patterns: ["memory.md"], roots: ["/x", "/z"])
    let updated = store.scans().first { $0.id == a.id }
    #expect(updated?.name == "A2")
    #expect(updated?.patterns == ["memory.md"])
    #expect(updated?.roots == ["/x", "/z"])

    store.removeScan(b)
    #expect(store.scans().map(\.name) == ["A2"])
}

@MainActor @Test func scanCanonicalPersists() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)

    let s = store.addScan(name: "C", patterns: ["CLAUDE.md"], roots: ["/x"])
    #expect(s.canonicalPath == nil)
    store.setCanonical("/x/CLAUDE.md", for: s)
    #expect(store.scans().first?.canonicalPath == "/x/CLAUDE.md")
    store.setCanonical(nil, for: s)
    #expect(store.scans().first?.canonicalPath == nil)
}
