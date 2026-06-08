import Foundation

/// Recursively sweeps root folders for files matching any pattern.
/// Pure and `nonisolated` so it can run off the main thread.
public enum ScanEngine {

    /// Directories never descended into.
    public static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".build", ".svn", "DerivedData", "Pods",
    ]

    public static func run(
        patterns: [String],
        roots: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var matches: [URL] = []
        var seen = Set<String>()
        for root in roots {
            sweep(root, patterns: patterns, fileManager: fileManager, into: &matches, seen: &seen)
        }
        return matches.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func sweep(
        _ directory: URL,
        patterns: [String],
        fileManager: FileManager,
        into matches: inout [URL],
        seen: inout Set<String>
    ) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []  // do NOT skip hidden — we want dotfiles like .env
        ) else { return }

        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }  // avoid symlink loops

            if values?.isDirectory == true {
                if ignoredDirectories.contains(url.lastPathComponent) { continue }
                sweep(url, patterns: patterns, fileManager: fileManager, into: &matches, seen: &seen)
            } else if PatternMatcher.matchesAny(filename: url.lastPathComponent, patterns: patterns) {
                if seen.insert(url.path).inserted { matches.append(url) }
            }
        }
    }
}
