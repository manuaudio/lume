import Foundation

/// Decides whether a batch of changed file paths can affect the library's
/// cached projections (favorites / group members / hidden flags). FSEvents
/// churn under untracked paths (e.g. a `git checkout`) only needs the
/// enumeration-cache invalidation, not a full SwiftData re-read.
public enum LibraryChangeFilter {
    public static func affectsLibrary(
        changed: Set<String>,
        favoritePaths: [String],
        hiddenPaths: Set<String>,
        groupFilePaths: [String: [String]]
    ) -> Bool {
        guard !changed.isEmpty else { return false }
        if favoritePaths.contains(where: changed.contains) { return true }
        if !hiddenPaths.isDisjoint(with: changed) { return true }
        for members in groupFilePaths.values where members.contains(where: changed.contains) {
            return true
        }
        return false
    }
}
