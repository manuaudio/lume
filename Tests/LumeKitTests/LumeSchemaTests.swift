import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func versionedSchemaCoversAllSixModels() throws {
    #expect(LumeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    let schema = Schema(versionedSchema: LumeSchemaV1.self)
    let names = Set(schema.entities.map(\.name))
    #expect(names == ["Favorite", "Bookmark", "Tag", "FileMeta", "Scan", "ContextBundle"])
}

@MainActor @Test func containerOpensWithMigrationPlan() throws {
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV1.self),
        migrationPlan: LumeMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    defer { withExtendedLifetime(container) {} }
    // Every model in the plan round-trips.
    let context = container.mainContext
    context.insert(Favorite(path: "/f", kindRaw: "markdown"))
    context.insert(Bookmark(path: "/b"))
    context.insert(Tag(name: "t"))
    context.insert(FileMeta(path: "/m"))
    context.insert(Scan(name: "s", patterns: ["*.md"], roots: ["/r"]))
    context.insert(ContextBundle(name: "c", paths: ["/p"]))
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<ContextBundle>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<Bookmark>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<LumeKit.Tag>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<FileMeta>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<Scan>()).count == 1)
}
