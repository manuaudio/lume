import Testing
import SwiftData
@testable import LumeKit

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self, Scan.self, ContextBundle.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

@MainActor @Test func bundleModelPersistsFields() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext

    let bundle = ContextBundle(name: "Prod context", paths: ["/p/CLAUDE.md", "/p/.env"])
    context.insert(bundle)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ContextBundle>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.name == "Prod context")
    #expect(fetched.first?.paths == ["/p/CLAUDE.md", "/p/.env"])
}
