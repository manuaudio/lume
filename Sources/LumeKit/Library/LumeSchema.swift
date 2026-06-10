import SwiftData

/// Versioned snapshot of the store layout (audit A3b). ALL container creation
/// (app + tests) goes through this so any future model change becomes an
/// explicit `LumeSchemaV2` + migration stage instead of relying on implicit
/// lightweight migration (Models.swift documents prior launch crashes from
/// exactly that).
public enum LumeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self, ContextBundle.self]
    }
}

public enum LumeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [LumeSchemaV1.self] }
    /// Empty: V1 is the first versioned snapshot of the existing layout, so
    /// existing stores adopt it without a stage. The next schema change adds
    /// LumeSchemaV2 and its stage here — that is also where the vestigial
    /// `Bookmark` model finally gets dropped (see LibraryStore bookmark notes).
    public static var stages: [MigrationStage] { [] }
}
