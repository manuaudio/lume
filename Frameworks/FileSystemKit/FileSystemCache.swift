import Foundation
import Observation

/// A main-actor cache over directory enumeration. The sidebar re-renders its
/// tree on every metadata edit; without a cache each re-render re-reads every
/// expanded directory from disk (`contentsOfDirectory` + a per-entry
/// `resourceValues` syscall) on the main thread. This caches the enumerated
/// `[FileNode]` per `(path, includeHidden)` so re-renders are pure memory reads.
///
/// External changes (Finder, other apps) are surfaced by `DirectoryWatcher`,
/// which calls `invalidate(path:)`; the bumped `revision` lets observing views
/// re-read just the changed directories.
@MainActor
@Observable
public final class FileSystemCache {
    private let files: FileServicing

    /// Keyed by `"\(path)|\(includeHidden)"` so the hidden/non-hidden variants
    /// of one directory are cached independently.
    @ObservationIgnored private var cache: [String: [FileNode]] = [:]

    /// Bumped on every invalidation. Views depend on it to re-read after an
    /// external filesystem change. Observed (no `@ObservationIgnored`).
    public private(set) var revision: Int = 0

    public init(files: FileServicing = FileService()) {
        self.files = files
    }

    private func key(_ path: String, _ includeHidden: Bool) -> String {
        "\(path)|\(includeHidden)"
    }

    /// Cached children of `url`. Returns the cached array if present (no disk
    /// access); otherwise enumerates ONCE (so the first paint shows content),
    /// stores, and returns. Enumeration failures cache an empty array so a
    /// missing/permission-denied directory isn't re-hit every render.
    public func children(of url: URL, includeHidden: Bool) -> [FileNode] {
        let k = key(url.path, includeHidden)
        if let cached = cache[k] { return cached }
        let nodes = (try? files.enumerate(url, includeHidden: includeHidden)) ?? []
        cache[k] = nodes
        return nodes
    }

    /// Whether `path`'s enumeration is currently cached. After an FSEvents tick
    /// only the invalidated directories are cache MISSES, so observers can use
    /// this to re-read just the changed directory instead of every mounted view.
    public func isCached(path: String, includeHidden: Bool) -> Bool {
        cache[key(path, includeHidden)] != nil
    }

    /// Drop both the hidden and non-hidden cache entries for `path` and bump
    /// `revision` so observers re-read it.
    public func invalidate(path: String) {
        cache.removeValue(forKey: key(path, true))
        cache.removeValue(forKey: key(path, false))
        revision &+= 1
    }

    /// Clear the entire cache and bump `revision`.
    public func invalidateAll() {
        cache.removeAll()
        revision &+= 1
    }
}
