import Foundation
import SwiftData

@Model public final class Favorite {
    @Attribute(.unique) public var path: String
    public var kindRaw: String
    public var dateAdded: Date
    /// User-defined order within the Favorites list (drag to reorder).
    public var sortIndex: Int

    public init(path: String, kindRaw: String, dateAdded: Date = .now, sortIndex: Int = 0) {
        self.path = path
        self.kindRaw = kindRaw
        self.dateAdded = dateAdded
        self.sortIndex = sortIndex
    }
}

/// A folder pinned to the top of the Browse sidebar (a Finder-style alias).
/// Independent of `Favorite` so a folder can be both bookmarked and favorited.
@Model public final class Bookmark {
    @Attribute(.unique) public var path: String
    public var dateAdded: Date
    /// User-defined order within the Browse Locations list (drag to reorder).
    public var sortIndex: Int

    public init(path: String, dateAdded: Date = .now, sortIndex: Int = 0) {
        self.path = path
        self.dateAdded = dateAdded
        self.sortIndex = sortIndex
    }
}

@Model public final class Tag {
    @Attribute(.unique) public var name: String
    /// Index into `TagPalette.swatches` (0…7), resolved to a real color at the
    /// UI layer. A PROPERTY-LEVEL default is required so existing stores migrate
    /// without a launch crash when this additive field appears.
    public var colorIndex: Int = 0
    public var files: [FileMeta]

    public init(name: String, colorIndex: Int = 0, files: [FileMeta] = []) {
        self.name = name
        self.colorIndex = colorIndex
        self.files = files
    }
}

@Model public final class FileMeta {
    @Attribute(.unique) public var path: String
    public var info: String
    /// Optional user-given label shown instead of the filename (e.g. name a
    /// `.env` "Chief — prod keys" so 10 `.env` files are distinguishable).
    public var displayName: String
    /// When true, this path is hidden from both sidebar regions unless the
    /// global "Show hidden" toggle is on. The property-level default (`= false`)
    /// is what lets SwiftData lightweight-migrate an existing store: without it
    /// the new non-optional attribute is "mandatory" with no value for old rows
    /// and migration fails fatally at launch.
    public var hidden: Bool = false
    @Relationship(inverse: \Tag.files) public var tags: [Tag]

    public init(path: String, info: String = "", displayName: String = "", hidden: Bool = false, tags: [Tag] = []) {
        self.path = path
        self.info = info
        self.displayName = displayName
        self.hidden = hidden
        self.tags = tags
    }
}

/// A favorite that lives on a remote source (SSH host or GitHub repo). Kept in
/// its own table — not folded into `Favorite` — because `Favorite.path` is the
/// unique key and is interpreted as a LOCAL filesystem path throughout the
/// favorites renderer, and two hosts can legitimately pin the same path string.
/// `ref` is the dedup key; the component fields are stored separately so nothing
/// has to parse `ref` back.
@Model public final class RemoteFavorite {
    @Attribute(.unique) public var ref: String   // "ssh:web1:/etc/x" | "github:owner/repo:/docs/a.md"
    public var sourceKindRaw: String              // "ssh" | "github"
    public var sourceKey: String                  // host alias | repo slug
    public var path: String                       // remote path
    public var isDirectory: Bool                  // folder → reroot tree; file → open
    public var dateAdded: Date
    /// Shared ordering space with `Favorite.sortIndex` (the merged sidebar list).
    public var sortIndex: Int

    public init(ref: String, sourceKindRaw: String, sourceKey: String, path: String,
                isDirectory: Bool, dateAdded: Date = .now, sortIndex: Int = 0) {
        self.ref = ref
        self.sourceKindRaw = sourceKindRaw
        self.sourceKey = sourceKey
        self.path = path
        self.isDirectory = isDirectory
        self.dateAdded = dateAdded
        self.sortIndex = sortIndex
    }
}
