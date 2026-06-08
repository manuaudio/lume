import Foundation
import SwiftData

/// A saved set of files whose *contents* can be re-copied as LLM context.
@Model public final class ContextBundle {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Ordered POSIX paths of the files in this bundle.
    public var paths: [String]
    public var sortIndex: Int = 0
    public var dateAdded: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String,
        paths: [String],
        sortIndex: Int = 0,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.name = name
        self.paths = paths
        self.sortIndex = sortIndex
        self.dateAdded = dateAdded
    }
}
