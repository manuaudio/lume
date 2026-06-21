import Foundation

/// Recursively walks a `FileSource` for files matching the config patterns.
/// Best-effort: directories that fail to list are skipped silently. Prunes
/// the same directories `ScanEngine` ignores, skips symlinked directories,
/// and bounds recursion depth.
public enum ConfigScanner {
    public static let maxDepth = 8

    public static func scan(
        source: any FileSource,
        roots: [String],
        patterns: [String] = ConfigPatterns.aiConfig
    ) async -> [ConfigFile] {
        var out: [ConfigFile] = []
        var seen = Set<String>()
        for root in roots {
            await sweep(source: source, path: root, patterns: patterns,
                        depth: 0, into: &out, seen: &seen)
        }
        return out.sorted {
            $0.ref.path.localizedStandardCompare($1.ref.path) == .orderedAscending
        }
    }

    private static func sweep(
        source: any FileSource,
        path: String,
        patterns: [String],
        depth: Int,
        into out: inout [ConfigFile],
        seen: inout Set<String>
    ) async {
        guard depth <= maxDepth else { return }
        let listing: [ResourceNode]
        do {
            listing = try await source.list(path, includeHidden: true)
        } catch {
            return  // unreadable directory — skip
        }
        for child in listing {
            if child.isSymlink { continue }
            if child.isDirectory {
                if ScanEngine.ignoredDirectories.contains(child.name) { continue }
                await sweep(source: source, path: child.ref.path, patterns: patterns,
                            depth: depth + 1, into: &out, seen: &seen)
            } else if PatternMatcher.matchesAny(filename: child.name, patterns: patterns) {
                guard seen.insert(child.ref.path).inserted else { continue }
                let size = try? await source.stat(child.ref.path).size
                out.append(ConfigFile(ref: child.ref, size: size))
            }
        }
    }
}
