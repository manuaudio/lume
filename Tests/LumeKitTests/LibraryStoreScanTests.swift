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
