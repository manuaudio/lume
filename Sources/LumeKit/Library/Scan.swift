import Foundation
import SwiftData

/// A saved sweep recipe: filename patterns to look for, under a set of root folders.
@Model public final class Scan {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Filename patterns: exact names ("CLAUDE.md") or globs ("*.env"). Case-insensitive.
    public var patterns: [String]
    /// Root folder POSIX paths to recurse from.
    public var roots: [String]
    public var sortIndex: Int
    public var dateAdded: Date

    public init(
        id: UUID = UUID(),
        name: String,
        patterns: [String],
        roots: [String],
        sortIndex: Int = 0,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.name = name
        self.patterns = patterns
        self.roots = roots
        self.sortIndex = sortIndex
        self.dateAdded = dateAdded
    }
}
