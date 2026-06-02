import Foundation
import SwiftData

@Model public final class Favorite {
    @Attribute(.unique) public var path: String
    public var kindRaw: String
    public var dateAdded: Date

    public init(path: String, kindRaw: String, dateAdded: Date = .now) {
        self.path = path
        self.kindRaw = kindRaw
        self.dateAdded = dateAdded
    }
}

/// A folder pinned to the top of the Browse sidebar (a Finder-style alias).
/// Independent of `Favorite` so a folder can be both bookmarked and favorited.
@Model public final class Bookmark {
    @Attribute(.unique) public var path: String
    public var dateAdded: Date

    public init(path: String, dateAdded: Date = .now) {
        self.path = path
        self.dateAdded = dateAdded
    }
}

@Model public final class Tag {
    @Attribute(.unique) public var name: String
    public var files: [FileMeta]

    public init(name: String, files: [FileMeta] = []) {
        self.name = name
        self.files = files
    }
}

@Model public final class FileMeta {
    @Attribute(.unique) public var path: String
    public var info: String
    @Relationship(inverse: \Tag.files) public var tags: [Tag]

    public init(path: String, info: String = "", tags: [Tag] = []) {
        self.path = path
        self.info = info
        self.tags = tags
    }
}
