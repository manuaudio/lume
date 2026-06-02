import Foundation

/// Which sidebar section a row belongs to (rows of the same path in different
/// sections must stay distinct for `List(selection:)`).
enum SidebarSection: String { case pinned, browser }

/// One selectable row in the unified sidebar.
struct SidebarRow: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var id: String { "\(section.rawValue)|\(url.path)" }
}
