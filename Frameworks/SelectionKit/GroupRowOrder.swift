import Foundation

/// Pure, cache-only ordering of the GROUPS region's flat row ids: each tag's
/// header, followed (when that group is expanded) by one file-row id per cached
/// member path, in cache order. No disk access. Mirrors the GROUPS loop that the
/// sidebar's keyboard-order walk used to inline, so render order and keyboard
/// order share one definition.
public enum GroupRowOrder {
    public static func ids(tagNames: [String],
                           expandedGroups: Set<String>,
                           groupFilePaths: [String: [String]]) -> [String] {
        var ids: [String] = []
        for name in tagNames {
            ids.append(GroupRowID.headerID(tagName: name))
            guard expandedGroups.contains(name) else { continue }
            for path in groupFilePaths[name] ?? [] {
                ids.append(GroupRowID.fileID(tagName: name, path: path))
            }
        }
        return ids
    }
}
