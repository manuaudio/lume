import SwiftData

/// Versioned snapshot of the store layout (audit A3b). ALL container creation
/// (app + tests) goes through this so any model change is an explicit schema
/// version + migration stage, never implicit lightweight migration
/// (Models.swift documents prior launch crashes from exactly that).
public enum LumeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self, ContextBundle.self]
    }
}

/// V2 adds `RemoteFavorite` (all-encompassing favorites). Pure addition of a new
/// entity, so the V1→V2 stage is lightweight: no existing row is transformed and
/// the new table starts empty. Vestigial `Bookmark` stays for now (deferred drop).
public enum LumeSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self,
         ContextBundle.self, RemoteFavorite.self]
    }
}

public enum LumeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [LumeSchemaV1.self, LumeSchemaV2.self]
    }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LumeSchemaV1.self, toVersion: LumeSchemaV2.self)]
    }
}
