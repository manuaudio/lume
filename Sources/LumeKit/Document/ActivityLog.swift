import Foundation

/// One recently-changed file.
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let date: Date
    public var id: String { path }
    public init(path: String, date: Date) { self.path = path; self.date = date }
}

/// A capped, deduped, newest-first log of recently-changed files (session-scoped).
public struct ActivityLog: Equatable, Sendable {
    public private(set) var entries: [ActivityEntry] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    /// Upsert a path to the front with `date`; removes any prior entry for it; caps to `limit`.
    public mutating func record(_ path: String, at date: Date) {
        entries.removeAll { $0.path == path }
        entries.insert(ActivityEntry(path: path, date: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func record(_ paths: [String], at date: Date) {
        for path in paths { record(path, at: date) }
    }

    public mutating func clear() { entries.removeAll() }

    /// True if any path component is a vendored/ignored directory.
    public static func isIgnored(_ path: String) -> Bool {
        let components = Set((path as NSString).pathComponents)
        return !components.isDisjoint(with: ScanEngine.ignoredDirectories)
    }
}
