import Foundation

/// The single source of truth for which children a sidebar tree shows. Pure (no
/// disk access): callers pass in the already-enumerated nodes. Replaces the
/// duplicated `visibleChildren` filters that previously had to be kept in
/// lockstep across FileTreeView and SidebarView.
public enum VisibleChildrenFilter {
    /// - Parameter isPinned: true for the FAVORITES region (applies the
    ///   pinned-hidden filter); false for the browser (shows reality).
    public static func apply(_ nodes: [FileNode],
                             filesOnly: Bool,
                             isPinned: Bool,
                             showPinnedHidden: Bool,
                             hiddenPaths: Set<String>,
                             browseFilter: String) -> [FileNode] {
        var out = nodes
        if filesOnly { out = out.filter { !$0.isDirectory } }
        if isPinned, !showPinnedHidden {
            out = out.filter { !hiddenPaths.contains($0.url.path) }
        }
        if !browseFilter.isEmpty {
            out = out.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(browseFilter) }
        }
        return out
    }
}
