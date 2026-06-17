import Testing
import SwiftData
import Foundation
@testable import LumeKit

@MainActor @Test func v1SchemaCoversOriginalSixModels() throws {
    #expect(LumeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    let names = Set(Schema(versionedSchema: LumeSchemaV1.self).entities.map(\.name))
    #expect(names == ["Favorite", "Bookmark", "Tag", "FileMeta", "Scan", "ContextBundle"])
}

@MainActor @Test func v2SchemaAddsRemoteFavorite() throws {
    #expect(LumeSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    let names = Set(Schema(versionedSchema: LumeSchemaV2.self).entities.map(\.name))
    #expect(names == ["Favorite", "Bookmark", "Tag", "FileMeta", "Scan", "ContextBundle", "RemoteFavorite"])
}

@MainActor @Test func containerOpensAtV2WithMigrationPlan() throws {
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV2.self),
        migrationPlan: LumeMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext
    context.insert(Favorite(path: "/f", kindRaw: "markdown"))
    context.insert(RemoteFavorite(ref: "ssh:web1:/etc/x", sourceKindRaw: "ssh",
                                  sourceKey: "web1", path: "/etc/x", isDirectory: false))
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<RemoteFavorite>()).count == 1)
}

/// The critical safety test: a store written under V1 (local favorites only)
/// must open under V2 with its data intact and the new table usable.
@MainActor @Test func v1StoreMigratesToV2WithoutDataLoss() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumeMigrationTest-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: url) }

    // 1) Write a V1 store with one favorite, then tear the container down.
    do {
        let v1 = try ModelContainer(
            for: Schema(versionedSchema: LumeSchemaV1.self),
            configurations: [ModelConfiguration(schema: Schema(versionedSchema: LumeSchemaV1.self), url: url)]
        )
        v1.mainContext.insert(Favorite(path: "/kept.md", kindRaw: "markdown"))
        try v1.mainContext.save()
        withExtendedLifetime(v1) {}
    }

    // 2) Reopen the same file under V2 + the migration plan.
    let v2 = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV2.self),
        migrationPlan: LumeMigrationPlan.self,
        configurations: [ModelConfiguration(schema: Schema(versionedSchema: LumeSchemaV2.self), url: url)]
    )
    defer { withExtendedLifetime(v2) {} }
    let favs = try v2.mainContext.fetch(FetchDescriptor<Favorite>())
    #expect(favs.map(\.path) == ["/kept.md"])               // local data survived
    v2.mainContext.insert(RemoteFavorite(ref: "github:o/r:/a.md", sourceKindRaw: "github",
                                         sourceKey: "o/r", path: "/a.md", isDirectory: false))
    try v2.mainContext.save()
    #expect(try v2.mainContext.fetch(FetchDescriptor<RemoteFavorite>()).count == 1)
}
