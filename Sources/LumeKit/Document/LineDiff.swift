import Foundation

/// One line of a unified diff.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case same, added, removed }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// Sync state of a copy relative to a canonical file.
public enum SyncStatus: Sendable, Equatable { case canonical, same, differs, unreadable }

/// Pure line-level diff built on the standard-library `CollectionDifference`.
public enum LineDiff {
    /// Unified line diff old→new. `.added` = in new not old; `.removed` = in old not new.
    public static func compute(from old: String, to new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [DiffLine] = []
        var oi = 0, ni = 0
        while oi < oldLines.count || ni < newLines.count {
            if oi < oldLines.count && removed.contains(oi) {
                result.append(DiffLine(kind: .removed, text: oldLines[oi])); oi += 1
            } else if ni < newLines.count && inserted.contains(ni) {
                result.append(DiffLine(kind: .added, text: newLines[ni])); ni += 1
            } else {
                result.append(DiffLine(kind: .same, text: oldLines[oi])); oi += 1; ni += 1
            }
        }
        return result
    }
}
