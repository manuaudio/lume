import Foundation

/// Which sidebar section a row belongs to (rows of the same path in different
/// sections must stay distinct for `List(selection:)`).
enum SidebarSection: String { case pinned, browser }

/// One selectable row in the unified sidebar.
struct SidebarRow: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var id: String { "\(section.rawValue)|\(isDirectory ? "d" : "f")|\(url.path)" }

    /// Decode a row id ("section|d|/path") back to its file + kind. Paths may
    /// contain "|", so only the first two segments are split off.
    static func decode(_ id: String) -> (url: URL, isDirectory: Bool)? {
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (URL(fileURLWithPath: String(parts[2])), parts[1] == "d")
    }
}
