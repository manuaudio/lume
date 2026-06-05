import Foundation
import SelectionKit

/// Which sidebar section a row belongs to (rows of the same path in different
/// sections must stay distinct for `List(selection:)`). `group` covers GROUPS
/// region rows; their full id grammar lives in `SelectionKit.GroupRowID`.
enum SidebarSection: String { case pinned, browser, group }

/// One selectable real-file/folder row in the unified sidebar (FAVORITES + OPEN
/// FOLDER). GROUPS rows use `GroupRowID` instead.
struct SidebarRow: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var id: String { "\(section.rawValue)|\(isDirectory ? "d" : "f")|\(url.path)" }

    /// Decode a row id back to its file + kind. Handles BOTH the real-file grammar
    /// ("section|d|/path") AND a file-under-group id ("groupfile|f|tag|/path"),
    /// returning the file URL in both cases so selection-derived URL collections
    /// (Copy Paths, open, pin) work uniformly. A GROUP HEADER id ("group|g|tag")
    /// decodes to nil — it isn't a real file. Paths may contain "|".
    static func decode(_ id: String) -> (url: URL, isDirectory: Bool)? {
        // File-under-group rows resolve to their real file.
        if let url = GroupRowID.fileURL(forID: id) {
            return (url, false)
        }
        // Group headers are not files.
        if GroupRowID.decode(id) != nil { return nil }
        // Real pinned/browser rows.
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (URL(fileURLWithPath: String(parts[2])), parts[1] == "d")
    }
}
