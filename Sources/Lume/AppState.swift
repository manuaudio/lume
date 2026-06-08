import Foundation
import Observation
import AppKit
import LumeKit

@MainActor
@Observable
final class AppState {

    // MARK: - Open Folder (browser)

    /// The opened folder — the breadcrumb's home and the browser's ceiling.
    private(set) var rootURL: URL?
    /// The directory currently shown in the Open Folder region (drill-in/up).
    private(set) var browseURL: URL?

    // MARK: - Selection / open document

    /// The file selected in the sidebar (drives the detail pane).
    var selectedURL: URL?
    /// The open document's text (bound to the editor). Nil when nothing/binary.
    var documentText: String?
    /// Kind of the current selection, drives which detail view shows.
    private(set) var selectedKind: FileKind = .unsupported
    /// Whether the open document has unsaved edits.
    private(set) var isDirty = false
    /// A user-facing, non-fatal error message for the detail pane.
    private(set) var errorMessage: String?

    // MARK: - Filters (sidebar)

    /// Hide directories in the browser (show files only).
    var filesOnly = false
    /// Include dotfiles / system-hidden entries in the browser.
    var showBrowserHidden = false
    /// Show user-hidden items in the Favorites region.
    var showPinnedHidden = false
    /// Case-insensitive name filter applied to browser/pinned files.
    var browseFilter = ""

    /// True while the user holds ⌃ to peek — temporarily reveals hidden items.
    var peeking = false

    /// Effective hidden visibility (real toggle OR a transient ⌃-peek).
    var effectiveShowBrowserHidden: Bool { showBrowserHidden || peeking }
    var effectiveShowPinnedHidden: Bool { showPinnedHidden || peeking }

    /// Whether config files default to the structured editor (else Raw). Persisted.
    var configStructuredByDefault: Bool =
        (UserDefaults.standard.object(forKey: "configStructuredByDefault") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(configStructuredByDefault, forKey: "configStructuredByDefault") }
    }
    /// Per-file Structured/Raw overrides (true = Raw) for the current session.
    private var configRawOverrides: [String: Bool] = [:]

    func configShowsRaw(forPath path: String) -> Bool {
        configRawOverrides[path] ?? !configStructuredByDefault
    }
    func setConfigShowsRaw(_ raw: Bool, forPath path: String) {
        configRawOverrides[path] = raw
    }

    // MARK: - Multi-selection (Finder-style)

    /// The set of selected sidebar row ids (across all regions).
    private(set) var selectedRowIDs: Set<String> = []
    /// Anchor for ⇧-range selection.
    private(set) var anchorID: String?
    /// Keyboard focus row (the moving end of a ⇧-range).
    private(set) var focusID: String?
    /// Folders expanded inline in the Open Folder tree (by path).
    private(set) var expandedPaths: Set<String> = []
    /// Pinned folders expanded inline in the Favorites region (by path).
    private(set) var expandedFavorites: Set<String> = []
    /// Accumulates type-ahead characters; reset after a short idle by the view.
    var typeaheadBuffer = ""
    /// The undo manager backing file operations (⌘Z).
    let undoManager = UndoManager()

    // MARK: - Library (SwiftData-backed)

    private(set) var library: LibraryStore?
    private(set) var favorites: [Favorite] = []
    private(set) var tags: [Tag] = []
    private(set) var hiddenPaths: Set<String> = []
    private(set) var scans: [Scan] = []

    // Active scan triage session
    private(set) var activeScan: Scan?
    private(set) var scanResults: [URL] = []
    private(set) var tickedPaths: Set<String> = []
    var scanFocusURL: URL?
    private(set) var isScanning = false
    private var scanGeneration = 0

    // MARK: - Propagate (canonical sync) state

    enum OverwriteRequest: Equatable {
        case single(URL)
        case allDiffering([URL])
        var targets: [URL] {
            switch self {
            case .single(let u): return [u]
            case .allDiffering(let us): return us
            }
        }
    }

    /// Staged overwrite awaiting confirmation; non-nil drives the confirm dialog.
    var pendingOverwrite: OverwriteRequest?
    /// Sync state of each active-scan result vs the canonical file (path → status).
    private(set) var syncStatus: [String: SyncStatus] = [:]

    /// The canonical file for the active scan, if one is set.
    var canonicalURL: URL? {
        guard let p = activeScan?.canonicalPath else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Results that differ from the canonical file.
    var differingURLs: [URL] { scanResults.filter { syncStatus[$0.path] == .differs } }

    // MARK: - Context bundles state

    static let contextFormatKey = "lume.contextFormat"

    /// Persisted XML/Markdown choice for "Copy as Context".
    var contextFormat: ContextFormat =
        ContextFormat(rawValue: UserDefaults.standard.string(forKey: AppState.contextFormatKey) ?? "") ?? .xml {
        didSet { UserDefaults.standard.set(contextFormat.rawValue, forKey: AppState.contextFormatKey) }
    }

    /// Files staged for copy that include secrets, awaiting user confirmation.
    /// Non-nil drives the secret-confirmation dialog.
    var pendingContextCopy: [URL]?

    private(set) var bundles: [ContextBundle] = []
    /// When non-nil, the detail pane shows this bundle (see ContentView routing).
    var activeBundle: ContextBundle?

    // New/edit scan sheet
    var presentingScanEditor = false
    var scanDraftName = ""
    var scanDraftPatterns = ""        // comma-separated in the UI
    var scanDraftRoots: [URL] = []
    var editingScan: Scan?            // nil = creating, non-nil = editing

    /// Tag names whose GROUP is expanded in the navigator.
    private(set) var expandedGroups: Set<String> = []
    /// Cached, display-name-sorted member paths per tag name (no disk access).
    private(set) var groupFilePaths: [String: [String]] = [:]
    /// Drives the New Group dialog (settable from the + button or the menu).
    var presentingNewGroup = false
    /// Bound to the New Group dialog's text field.
    var newGroupName = ""
    /// Drives the centralized Rename dialog.
    var presentingRename = false
    var renameText = ""
    private(set) var renameURL: URL?
    /// Toggled by ⌘F to focus the sidebar filter field.
    var focusFilterRequested = false
    /// When true, the editor's document tag header is shown.
    var showEditorTags = true
    /// Drives the multi-file Tag sheet.
    var presentingMultiTag = false
    /// Drives the Tag Manager sheet.
    var presentingTagManager = false

    // MARK: - Internals

    private var loadedText: String?
    private let files = FileService()
    /// Main-actor enumeration cache; FSEvents invalidations bump its `revision`.
    let cache = FileSystemCache()
    private var watcher: DirectoryWatcher?

    /// Kinds Lume edits as plain text in the editor (others get a viewer).
    static let textEditableKinds: Set<FileKind> = [.markdown, .env, .code]

    // MARK: - Activity feed
    private(set) var activity = ActivityLog()
    var recentChanges: [ActivityEntry] { activity.entries }
    func clearActivityLog() { activity.clear() }

    // MARK: - Library wiring

    /// Connect the SwiftData-backed library (called once the container is ready).
    func attach(library: LibraryStore) {
        self.library = library
        library.migrateBookmarksToFavorites()
        refreshLibrary()
    }

    /// Re-read the cached library projections (favorites / tags / hidden paths).
    func refreshLibrary() {
        guard let library else { return }
        favorites = library.favorites()
        tags = library.allTags()
        hiddenPaths = library.hiddenPaths()
        scans = library.scans()
        bundles = library.bundles()
        rebuildGroups()
    }

    /// Recompute each tag's sorted member paths (pure, off the SwiftData objects).
    private func rebuildGroups() {
        guard let library else { return }
        var map: [String: [String]] = [:]
        for tag in tags {
            let paths = Array(library.paths(taggedWith: tag.name))
            map[tag.name] = GroupSort.sorted(paths) { library.displayName(for: $0) }
        }
        groupFilePaths = map
        // Drop expansion state for tags that no longer exist.
        let names = Set(tags.map(\.name))
        expandedGroups.formIntersection(names)
    }

    // MARK: - Open folder

    /// Open a folder as the new root. Persists it for next launch.
    func openFolder(_ url: URL) {
        rootURL = url
        browseURL = url
        selectedURL = nil
        documentText = nil
        errorMessage = nil
        clearSelection()
        expandedPaths.removeAll()
        cache.invalidateAll()
        startWatching(url)
        Preferences.saveLastFolder(url)
    }

    /// Honor LUME_OPEN_FOLDER / LUME_OPEN_FILE launch environment (dev / scripting
    /// hand-off). Returns true if it opened a folder (so launch can skip restore).
    @discardableResult
    func applyLaunchEnvironment() -> Bool {
        let env = ProcessInfo.processInfo.environment
        var openedFolder = false
        if let folder = env["LUME_OPEN_FOLDER"], !folder.isEmpty {
            openFolder(URL(fileURLWithPath: folder))
            openedFolder = true
        }
        if let file = env["LUME_OPEN_FILE"], !file.isEmpty {
            choose(URL(fileURLWithPath: file))
        }
        return openedFolder
    }

    /// Restore the last folder, if its bookmark still resolves.
    func restoreLastFolder() {
        guard let url = Preferences.loadLastFolder() else { return }
        _ = url.startAccessingSecurityScopedResource()
        openFolder(url)
    }

    /// Watch the open tree; an external change invalidates the affected
    /// directories (so the browser re-reads just those) and refreshes the library.
    private func startWatching(_ root: URL) {
        watcher?.stop()
        watcher = DirectoryWatcher(root: root) { [weak self] changed in
            guard let self else { return }
            for path in changed { self.cache.invalidate(path: path) }
            // Sort for deterministic within-burst order (Set iteration is unordered;
            // entries share a timestamp so the order is cosmetic but should be stable).
            let recordable = changed.filter { !ActivityLog.isIgnored($0) && self.isRegularFile($0) }.sorted()
            if !recordable.isEmpty {
                var log = self.activity
                log.record(recordable, at: Date())
                self.activity = log
            }
            self.refreshLibrary()
        }
    }

    // MARK: - Browser navigation

    /// Clickable path segments from the open folder down to the current directory.
    var breadcrumb: [Breadcrumb.Segment] {
        guard let browseURL, let rootURL else { return [] }
        return Breadcrumb.segments(for: browseURL, home: rootURL)
    }

    /// Drill the browser into `url` (a directory).
    func navigate(to url: URL) {
        browseURL = url
        clearSelection()
    }

    /// Go up one directory, stopping at the opened folder (the breadcrumb home).
    func goUp() {
        guard let browseURL, let rootURL, browseURL.path != rootURL.path else { return }
        let parent = browseURL.deletingLastPathComponent()
        if parent.path.count >= rootURL.path.count { navigate(to: parent) }
    }

    /// Whether the browser can still go up (not already at the opened folder).
    var canGoUp: Bool {
        guard let browseURL, let rootURL else { return false }
        return browseURL.path != rootURL.path
    }

    /// Filtered children of one browser directory (cache-backed).
    func visibleChildren(of url: URL) -> [FileNode] {
        let nodes = cache.children(of: url, includeHidden: effectiveShowBrowserHidden)
        return VisibleChildrenFilter.apply(
            nodes,
            filesOnly: filesOnly,
            isPinned: false,
            showPinnedHidden: effectiveShowPinnedHidden,
            hiddenPaths: hiddenPaths,
            browseFilter: browseFilter
        )
    }

    /// One row of the Open Folder tree, depth-annotated for indentation.
    struct BrowserRowItem: Identifiable, Equatable {
        let node: FileNode
        let depth: Int
        var id: String { node.url.path }
    }

    /// Flattened tree from `browseURL`, expanding `expandedPaths`. Drives both
    /// the rendered rows (with indent) and the keyboard traversal order.
    var browserRows: [BrowserRowItem] {
        _ = cache.revision   // observe FSEvents invalidations
        guard let browseURL else { return [] }
        var out: [BrowserRowItem] = []
        func walk(_ dir: URL, _ depth: Int) {
            for node in visibleChildren(of: dir) {
                out.append(BrowserRowItem(node: node, depth: depth))
                if node.isDirectory, expandedPaths.contains(node.url.path) {
                    walk(node.url, depth + 1)
                }
            }
        }
        walk(browseURL, 0)
        return out
    }

    func isExpanded(_ url: URL) -> Bool { expandedPaths.contains(url.path) }

    func toggleExpanded(_ url: URL) {
        if expandedPaths.contains(url.path) { expandedPaths.remove(url.path) }
        else { expandedPaths.insert(url.path) }
    }

    // MARK: - Favorites (pinning)

    /// Pinned items, minus user-hidden ones unless `showPinnedHidden` (or peeking).
    var visibleFavorites: [Favorite] {
        favorites.filter { effectiveShowPinnedHidden || !hiddenPaths.contains($0.path) }
    }

    func isFavorite(_ url: URL) -> Bool {
        library?.isFavorite(path: url.path) ?? false
    }

    func toggleFavorite(_ node: FileNode) {
        toggleFavorite(url: node.url, isDirectory: node.isDirectory)
    }

    func toggleFavorite(url: URL, isDirectory: Bool) {
        guard let library else { return }
        if library.isFavorite(path: url.path) {
            library.removeFavorite(path: url.path)
        } else if isDirectory {
            library.addFavoriteFolder(path: url.path)
        } else {
            library.addFavorite(path: url.path, kind: FileKind.detect(filename: url.lastPathComponent))
        }
        refreshLibrary()
    }

    /// Whether a stored favorite is a folder (persisted via the "folder" sentinel).
    func favoriteIsFolder(_ favorite: Favorite) -> Bool {
        favorite.kindRaw == "folder"
    }

    /// Filtered children of a pinned folder (applies the pinned-hidden filter).
    func visiblePinnedChildren(of url: URL) -> [FileNode] {
        let nodes = cache.children(of: url, includeHidden: effectiveShowBrowserHidden)
        return VisibleChildrenFilter.apply(
            nodes,
            filesOnly: filesOnly,
            isPinned: true,
            showPinnedHidden: effectiveShowPinnedHidden,
            hiddenPaths: hiddenPaths,
            browseFilter: browseFilter
        )
    }

    /// A row in the Favorites region (a pin root, or a child of an expanded pin).
    struct FavoriteRowItem: Identifiable, Equatable {
        let url: URL
        let isDirectory: Bool
        let depth: Int
        let isPinRoot: Bool
        var id: String { "\(isDirectory ? "d" : "f")|\(url.path)" }
    }

    /// Flattened Favorites rows: each visible pin, plus the children of expanded
    /// pinned folders (recursively).
    var favoriteRowItems: [FavoriteRowItem] {
        _ = cache.revision
        var out: [FavoriteRowItem] = []
        func walk(_ dir: URL, _ depth: Int) {
            for node in visiblePinnedChildren(of: dir) {
                out.append(FavoriteRowItem(url: node.url, isDirectory: node.isDirectory,
                                           depth: depth, isPinRoot: false))
                if node.isDirectory, expandedFavorites.contains(node.url.path) {
                    walk(node.url, depth + 1)
                }
            }
        }
        for fav in visibleFavorites {
            let url = URL(fileURLWithPath: fav.path)
            let isDir = favoriteIsFolder(fav)
            out.append(FavoriteRowItem(url: url, isDirectory: isDir, depth: 0, isPinRoot: true))
            if isDir, expandedFavorites.contains(fav.path) { walk(url, 1) }
        }
        return out
    }

    func isFavoriteExpanded(_ url: URL) -> Bool { expandedFavorites.contains(url.path) }

    func toggleFavoriteExpanded(_ url: URL) {
        if expandedFavorites.contains(url.path) { expandedFavorites.remove(url.path) }
        else { expandedFavorites.insert(url.path) }
    }

    /// A "fav|…" row id for any URL shown in the Favorites region.
    static func favoriteURLRowID(_ url: URL, isDirectory: Bool) -> String {
        "fav|\(isDirectory ? "d" : "f")|\(url.path)"
    }

    /// Pin files dropped onto the Favorites region.
    func pinDropped(_ urls: [URL]) {
        guard let library else { return }
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !library.isFavorite(path: url.path) {
                if isDir { library.addFavoriteFolder(path: url.path) }
                else { library.addFavorite(path: url.path, kind: FileKind.detect(filename: url.lastPathComponent)) }
            }
        }
        refreshLibrary()
    }

    // MARK: - Tags & GROUPS

    /// Tags carried by the file at `url` (for the document tag header), by name.
    func tags(forPath path: String) -> [Tag] {
        (library?.meta(for: path)?.tags ?? []).sorted { $0.name < $1.name }
    }

    /// Expand / collapse a GROUP in the navigator.
    func toggleGroup(_ name: String) {
        if expandedGroups.contains(name) { expandedGroups.remove(name) }
        else { expandedGroups.insert(name) }
    }

    func isGroupExpanded(_ name: String) -> Bool { expandedGroups.contains(name) }

    /// Request the New Group dialog (from a menu command or button).
    func beginNewGroup() {
        newGroupName = ""
        presentingNewGroup = true
    }

    /// Create a new, empty GROUP (idempotent by name).
    func createGroup(named name: String) {
        library?.createEmptyTag(named: name)
        refreshLibrary()
    }

    /// Add `tagName` to the file at `path`, preserving its other metadata.
    func addTag(_ tagName: String, toPath path: String) {
        guard let library else { return }
        let meta = library.meta(for: path)
        var names = meta?.tags.map(\.name) ?? []
        guard !names.contains(tagName) else { return }
        names.append(tagName)
        library.setMeta(path: path,
                        info: meta?.info ?? "",
                        tagNames: names,
                        displayName: meta?.displayName ?? "")
        refreshLibrary()
    }

    /// Remove ONE tag from ONE file (the group keeps existing even if emptied).
    func removeTag(_ tagName: String, fromPath path: String) {
        library?.removeTag(named: tagName, fromPath: path)
        refreshLibrary()
    }

    @discardableResult
    func renameGroup(_ oldName: String, to newName: String) -> Bool {
        let ok = library?.renameTag(named: oldName, to: newName) ?? false
        if ok { refreshLibrary() }
        return ok
    }

    func recolorGroup(_ name: String, colorIndex: Int) {
        library?.recolorTag(named: name, colorIndex: colorIndex)
        refreshLibrary()
    }

    func deleteGroup(_ name: String) {
        library?.deleteTag(named: name)
        refreshLibrary()
    }

    /// Tag names the user can still add to `path` (not already applied), for the
    /// add-tag popover's suggestions.
    func tagSuggestions(forPath path: String) -> [Tag] {
        let applied = Set(tags(forPath: path).map(\.name))
        return tags.filter { !applied.contains($0.name) }
    }

    // MARK: Multi-file tagging

    /// Tag names carried by EVERY file in the current selection (fully applied).
    func commonTagNamesInSelection() -> Set<String> {
        let urls = selectedURLs
        guard let first = urls.first, let library else { return [] }
        var common = Set(library.meta(for: first.path)?.tags.map(\.name) ?? [])
        for url in urls.dropFirst() {
            common.formIntersection(Set(library.meta(for: url.path)?.tags.map(\.name) ?? []))
            if common.isEmpty { break }
        }
        return common
    }

    /// Tag names carried by AT LEAST ONE file in the selection (mixed state).
    func anyTagNamesInSelection() -> Set<String> {
        guard let library else { return [] }
        var any = Set<String>()
        for url in selectedURLs { any.formUnion(library.meta(for: url.path)?.tags.map(\.name) ?? []) }
        return any
    }

    func addTagToSelection(_ name: String) {
        for url in selectedURLs { addTag(name, toPath: url.path) }
    }

    func removeTagFromSelection(_ name: String) {
        for url in selectedURLs { removeTag(name, fromPath: url.path) }
    }

    // MARK: Notes (FileMeta.info)

    func info(forPath path: String) -> String { library?.meta(for: path)?.info ?? "" }

    func setInfo(_ text: String, forPath path: String) {
        guard let library else { return }
        let meta = library.meta(for: path)
        library.setMeta(path: path,
                        info: text,
                        tagNames: meta?.tags.map(\.name) ?? [],
                        displayName: meta?.displayName ?? "")
        refreshLibrary()
    }

    // MARK: - Row ids & selection order

    /// Encode a browser/favorite row id compatible with `RowSelection`
    /// ("section|d-or-f|path"). Group rows use `GroupRowID`.
    static func browseRowID(_ node: FileNode) -> String {
        "browse|\(node.isDirectory ? "d" : "f")|\(node.url.path)"
    }
    static func favoriteRowID(_ favorite: Favorite, isFolder: Bool) -> String {
        "fav|\(isFolder ? "d" : "f")|\(favorite.path)"
    }

    /// Decode the file URL a row id points at (nil for group headers).
    func url(forRowID id: String) -> URL? {
        if id.hasPrefix("browse|") || id.hasPrefix("fav|") {
            let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 { return URL(fileURLWithPath: String(parts[2])) }
            return nil
        }
        return GroupRowID.fileURL(forID: id)
    }

    /// Flat top-to-bottom order of every currently-visible row, matching render
    /// order (GROUPS → Favorites → Open Folder). Drives ⇧-range selection.
    var visibleRowOrder: [String] {
        var ids: [String] = []
        ids += GroupRowOrder.ids(tagNames: tags.map(\.name),
                                 expandedGroups: expandedGroups,
                                 groupFilePaths: groupFilePaths)
        for item in favoriteRowItems {
            ids.append(Self.favoriteURLRowID(item.url, isDirectory: item.isDirectory))
        }
        for row in browserRows {
            ids.append(Self.browseRowID(row.node))
        }
        return ids
    }

    func isRowSelected(_ id: String) -> Bool { selectedRowIDs.contains(id) }

    /// Plain click: collapse the multi-selection to this one row.
    func selectSingle(_ id: String) {
        selectedRowIDs = [id]
        anchorID = id
        focusID = id
    }

    /// ⌘ / ⇧ click: extend the multi-selection without activating the row.
    func extendSelection(_ id: String, command: Bool, shift: Bool) {
        let result = RowSelection.click(
            target: id,
            current: selectedRowIDs,
            anchor: anchorID,
            in: visibleRowOrder,
            command: command,
            shift: shift
        )
        selectedRowIDs = result.selection
        anchorID = result.anchor
        focusID = result.focus
    }

    func clearSelection() {
        selectedRowIDs = []
        anchorID = nil
        focusID = nil
    }

    /// Route a row tap: ⌘/⇧ extend the multi-selection; a plain click collapses
    /// to this row and activates it (open file / drill folder / toggle group).
    func handleRowTap(_ id: String, command: Bool, shift: Bool, activate: () -> Void) {
        if command || shift {
            extendSelection(id, command: command, shift: shift)
        } else {
            selectSingle(id)
            activate()
        }
    }

    // MARK: - Keyboard navigation

    /// The single row the keyboard acts from (sole selection, else focus/anchor).
    private var keyboardCurrent: String? {
        if selectedRowIDs.count == 1 { return selectedRowIDs.first }
        return focusID ?? anchorID
    }

    var soleSelectedID: String? {
        if selectedRowIDs.count == 1 { return selectedRowIDs.first }
        return focusID
    }

    private func isDirectoryRow(_ id: String) -> Bool {
        if id.hasPrefix("group|g|") { return true }
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 && parts[1] == "d"
    }

    /// ↑/↓ — move the single selection one row.
    func moveSelection(by step: Int) {
        guard let r = RowSelection.move(from: keyboardCurrent, in: visibleRowOrder, by: step) else { return }
        selectedRowIDs = r.selection
        anchorID = r.anchor
        focusID = r.anchor
        openIfSingleFile()
    }

    /// ⇧↑/⇧↓ — extend the contiguous selection.
    func extendSelection(by step: Int) {
        let order = visibleRowOrder
        guard let anchor = anchorID, let focus = focusID,
              let r = RowSelection.extend(anchor: anchor, focus: focus, in: order, by: step) else {
            moveSelection(by: step); return
        }
        selectedRowIDs = r.selection
        focusID = r.focus
    }

    /// ⌘A — select every visible row.
    func selectAllRows() {
        let all = RowSelection.all(in: visibleRowOrder)
        selectedRowIDs = all
        anchorID = visibleRowOrder.first
        focusID = visibleRowOrder.last
    }

    /// Open the file if exactly one (non-directory) row is selected.
    private func openIfSingleFile() {
        guard let id = soleSelectedID, !isDirectoryRow(id), let url = url(forRowID: id) else { return }
        choose(url)
    }

    /// Return / ⌘↓ — open a file, drill into a browser folder, or toggle a group.
    func openOrDrillSelected() {
        guard let id = soleSelectedID else { return }
        if id.hasPrefix("group|g|"), case let .header(name)? = GroupRowID.decode(id) {
            toggleGroup(name); return
        }
        guard let url = url(forRowID: id) else { return }
        if isDirectoryRow(id) { navigate(to: url) } else { choose(url) }
    }

    /// → — expand a collapsed browser folder, else move into it.
    func expandOrDescend() {
        guard let id = soleSelectedID, isDirectoryRow(id),
              id.hasPrefix("browse|"), let url = url(forRowID: id) else { return }
        if !isExpanded(url) { toggleExpanded(url) } else { moveSelection(by: 1) }
    }

    /// ← — collapse an expanded browser folder, else jump to its parent row.
    func collapseOrAscend() {
        guard let id = soleSelectedID else { return }
        if id.hasPrefix("browse|"), isDirectoryRow(id),
           let url = url(forRowID: id), isExpanded(url) {
            toggleExpanded(url); return
        }
        selectParentRow(of: id)
    }

    private func selectParentRow(of id: String) {
        guard id.hasPrefix("browse|") || id.hasPrefix("fav|") else { return }
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let parent = URL(fileURLWithPath: String(parts[2])).deletingLastPathComponent()
        let parentID = "\(parts[0])|d|\(parent.path)"
        if visibleRowOrder.contains(parentID) { selectSingle(parentID) }
    }

    // MARK: - Keyboard-driven actions on the selection

    func trashSelection() { moveToTrash(selectedURLs) }

    func duplicateSelection() {
        if let id = soleSelectedID, !isDirectoryRow(id), let url = url(forRowID: id) {
            duplicate(url)
        } else if let first = selectedURLs.first {
            duplicate(first)
        }
    }

    func pinSelection() {
        for id in visibleRowOrder where selectedRowIDs.contains(id) {
            if let url = url(forRowID: id) { toggleFavorite(url: url, isDirectory: isDirectoryRow(id)) }
        }
    }

    /// The URL the rename command should target (sole selection or open doc).
    var renameTargetURL: URL? {
        if let id = soleSelectedID, let url = url(forRowID: id) { return url }
        return selectedURL
    }

    /// Open the centralized Rename dialog for a URL (or the current target).
    func beginRename(_ url: URL? = nil) {
        guard let target = url ?? renameTargetURL else { return }
        renameURL = target
        renameText = target.lastPathComponent
        presentingRename = true
    }

    func commitRename() {
        if let url = renameURL { rename(url, to: renameText) }
        presentingRename = false
    }

    /// Focus the sidebar filter field (⌘F).
    func requestFilterFocus() { focusFilterRequested.toggle() }

    // MARK: - Type-ahead

    /// Append a typed character and jump to the first visible row whose name
    /// starts with the accumulated buffer.
    func typeaheadAppend(_ character: Character) {
        typeaheadBuffer.append(character)
        jumpToTypeahead()
    }

    func resetTypeahead() { typeaheadBuffer = "" }

    private func jumpToTypeahead() {
        let needle = typeaheadBuffer.lowercased()
        guard !needle.isEmpty else { return }
        for id in visibleRowOrder {
            let name: String
            if let url = url(forRowID: id) {
                name = displayName(for: url).lowercased()
            } else if case let .header(tagName)? = GroupRowID.decode(id) {
                name = tagName.lowercased()
            } else { continue }
            if name.hasPrefix(needle) {
                selectSingle(id)
                openIfSingleFile()
                return
            }
        }
    }

    /// Resolved file URLs for the current multi-selection (drops group headers),
    /// in visible order. Falls back to the open document when nothing is multi-
    /// selected, so single-file actions still work.
    var selectedURLs: [URL] {
        let order = visibleRowOrder
        let urls = order.filter { selectedRowIDs.contains($0) }.compactMap { url(forRowID: $0) }
        if urls.isEmpty, let selectedURL { return [selectedURL] }
        return urls
    }

    // MARK: - File operations (with Undo)

    private let fm = FileManager.default

    /// True if `path` is an existing regular file (not a directory).
    private func isRegularFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Copy the selected files' POSIX paths to the clipboard (⌥⌘C).
    func copySelectedPaths() {
        let text = PathExport.clipboardString(for: selectedURLs)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Create a new folder in the current browse directory.
    func newFolder() {
        guard let dir = browseURL else { return }
        let url = FileOps.uniqueChild(in: dir, base: "untitled folder")
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            cache.invalidate(path: dir.path)
            registerUndo("New Folder") { [weak self] in self?.trashSilently([url]) }
        } catch {
            errorMessage = "Couldn't create folder: \(error.localizedDescription)"
        }
    }

    /// Rename a file/folder on disk (not its display label).
    func rename(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
        let dst = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try fm.moveItem(at: url, to: dst)
            cache.invalidate(path: url.deletingLastPathComponent().path)
            if selectedURL == url { choose(dst) }
            registerUndo("Rename") { [weak self] in self?.rename(dst, to: url.lastPathComponent) }
        } catch {
            errorMessage = "Couldn't rename \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Finder-style duplicate ("<name> copy").
    func duplicate(_ url: URL) {
        let dst = FileOps.duplicateURL(for: url)
        do {
            try fm.copyItem(at: url, to: dst)
            cache.invalidate(path: url.deletingLastPathComponent().path)
            registerUndo("Duplicate") { [weak self] in self?.trashSilently([dst]) }
        } catch {
            errorMessage = "Couldn't duplicate \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Move files to the Trash, undoably (restores them from the Trash).
    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var restores: [(trashed: URL, original: URL)] = []
        for u in urls {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &resulting)
                if let r = resulting as URL? { restores.append((r, u)) }
                cache.invalidate(path: u.deletingLastPathComponent().path)
                if selectedURL == u { selectedURL = nil; documentText = nil }
            } catch {
                errorMessage = "Couldn't trash \(u.lastPathComponent): \(error.localizedDescription)"
            }
        }
        clearSelection()
        registerUndo("Move to Trash") { [weak self] in
            guard let self else { return }
            for (trashed, original) in restores {
                try? self.fm.moveItem(at: trashed, to: original)
                self.cache.invalidate(path: original.deletingLastPathComponent().path)
            }
        }
    }

    /// Reveal the selection in Finder.
    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func isHidden(_ url: URL) -> Bool { hiddenPaths.contains(url.path) }

    /// Toggle the user-hidden flag for a set of files (hides if any are visible,
    /// else reveals all). Affects the Favorites region's pinned-hidden filter.
    func toggleHidden(_ urls: [URL]) {
        guard let library, !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        let shouldHide = paths.contains { !hiddenPaths.contains($0) }
        library.setHidden(shouldHide, paths: paths)
        refreshLibrary()
    }

    /// Set a display-only label for a file (preserves its other metadata). An
    /// empty string clears the override.
    func setDisplayName(_ url: URL, to name: String) {
        guard let library else { return }
        let meta = library.meta(for: url.path)
        library.setMeta(path: url.path,
                        info: meta?.info ?? "",
                        tagNames: meta?.tags.map(\.name) ?? [],
                        displayName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshLibrary()
    }

    // MARK: Undo plumbing

    private func registerUndo(_ name: String, _ action: @escaping () -> Void) {
        undoManager.registerUndo(withTarget: self) { _ in action() }
        undoManager.setActionName(name)
    }

    /// Trash without registering undo — used as the inverse of create/duplicate.
    private func trashSilently(_ urls: [URL]) {
        for u in urls {
            try? fm.trashItem(at: u, resultingItemURL: nil)
            cache.invalidate(path: u.deletingLastPathComponent().path)
        }
    }

    // MARK: - Scans

    func beginNewScan() {
        editingScan = nil
        scanDraftName = ""
        scanDraftPatterns = "CLAUDE.md, memory.md, aesthetics.md, .env"
        scanDraftRoots = []
        presentingScanEditor = true
    }

    func beginEditScan(_ scan: Scan) {
        editingScan = scan
        scanDraftName = scan.name
        scanDraftPatterns = scan.patterns.joined(separator: ", ")
        scanDraftRoots = scan.roots.map { URL(fileURLWithPath: $0) }
        presentingScanEditor = true
    }

    func commitScanEditor() {
        let patterns = scanDraftPatterns
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let roots = scanDraftRoots.map(\.path)
        let trimmedName = scanDraftName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? "Untitled Scan" : trimmedName
        guard let library, !patterns.isEmpty, !roots.isEmpty else {
            return   // invalid input: keep the editor open so the user can correct it
        }
        if let editingScan {
            library.updateScan(editingScan, name: name, patterns: patterns, roots: roots)
        } else {
            library.addScan(name: name, patterns: patterns, roots: roots)
        }
        refreshLibrary()
        presentingScanEditor = false
    }

    func deleteScan(_ scan: Scan) {
        if activeScan?.id == scan.id { closeScan() }
        library?.removeScan(scan)
        refreshLibrary()
    }

    func runScan(_ scan: Scan) {
        if activeBundle != nil { closeBundle() }
        scanGeneration += 1
        let generation = scanGeneration
        activeScan = scan
        selectedURL = nil          // hand the detail pane to the triage view
        tickedPaths = []
        scanResults = []
        scanFocusURL = nil
        isScanning = true

        let patterns = scan.patterns
        let roots = scan.roots.map { URL(fileURLWithPath: $0) }
        Task {
            let results = await Task.detached { ScanEngine.run(patterns: patterns, roots: roots) }.value
            guard self.scanGeneration == generation else { return }  // a newer scan/close superseded us
            self.scanResults = results
            self.scanFocusURL = results.first
            self.isScanning = false
        }
    }

    func rescanActive() {
        if let activeScan { runScan(activeScan) }
    }

    func closeScan() {
        scanGeneration += 1  // discard any in-flight sweep
        activeScan = nil
        scanResults = []
        tickedPaths = []
        scanFocusURL = nil
        isScanning = false
        pendingOverwrite = nil   // drop any staged (destructive) overwrite tied to this scan
        syncStatus = [:]
    }

    func isTicked(_ url: URL) -> Bool { tickedPaths.contains(url.path) }

    func toggleTick(_ url: URL) {
        if tickedPaths.contains(url.path) { tickedPaths.remove(url.path) }
        else { tickedPaths.insert(url.path) }
    }

    func toggleTickFocused() {
        if let scanFocusURL { toggleTick(scanFocusURL) }
    }

    var tickedURLs: [URL] { scanResults.filter { tickedPaths.contains($0.path) } }

    private func writeToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyTickedPaths() {
        writeToPasteboard(PathExport.clipboardString(for: tickedURLs))
    }

    func copyTickedAsPrompt() {
        writeToPasteboard(PathExport.promptString(for: tickedURLs))
    }

    // MARK: - Propagate (canonical sync) actions

    func setCanonical(_ url: URL?) {
        guard let library, let activeScan else { return }
        library.setCanonical(url?.path, for: activeScan)
        scans = library.scans()
        Task { await recomputeSyncStatus() }
    }

    /// Recompute each result's sync status vs the canonical file, off-main.
    func recomputeSyncStatus() async {
        guard let canonicalURL else { syncStatus = [:]; return }
        let canonicalPath = canonicalURL.path
        let results = scanResults.map(\.path)
        let computed = await Task.detached(priority: .utility) { () -> [String: SyncStatus] in
            guard let canonText = try? String(contentsOf: URL(fileURLWithPath: canonicalPath), encoding: .utf8) else {
                return [:]
            }
            var out: [String: SyncStatus] = [:]
            for p in results {
                if p == canonicalPath { out[p] = .canonical; continue }
                if let t = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8) {
                    out[p] = (t == canonText) ? .same : .differs
                } else {
                    out[p] = .unreadable
                }
            }
            return out
        }.value
        syncStatus = computed
    }

    func requestOverwrite(_ target: URL) { pendingOverwrite = .single(target) }

    func requestOverwriteAllDiffering() {
        let targets = differingURLs
        guard !targets.isEmpty else { return }
        pendingOverwrite = .allDiffering(targets)
    }

    func cancelOverwrite() { pendingOverwrite = nil }

    func confirmOverwrite() {
        defer { pendingOverwrite = nil }
        guard let req = pendingOverwrite, let canonicalURL else { return }
        overwrite(req.targets, withCanonical: canonicalURL)
    }

    /// Overwrite each target with the canonical file's text; registers a single undo.
    private func overwrite(_ targets: [URL], withCanonical canonical: URL) {
        guard let canonText = try? String(contentsOf: canonical, encoding: .utf8) else {
            errorMessage = "Couldn't read the canonical file."
            return
        }
        var restores: [(url: URL, text: String)] = []
        var skipped: [String] = []
        for target in targets where target.path != canonical.path {
            // Only overwrite files we can read back as UTF-8 text. A binary or
            // non-UTF-8 target has no faithful undo (we'd capture "" and restore an
            // empty file), so skip it entirely rather than risk destroying data.
            guard let old = try? String(contentsOf: target, encoding: .utf8) else {
                skipped.append(target.lastPathComponent)
                continue
            }
            do {
                try TextDocument(url: target, text: canonText).save()
                restores.append((target, old))
                cache.invalidate(path: target.deletingLastPathComponent().path)
            } catch {
                skipped.append(target.lastPathComponent)
            }
        }
        if !restores.isEmpty {
            registerUndo("Overwrite with Canonical") { [weak self] in
                for (url, text) in restores {
                    try? TextDocument(url: url, text: text).save()
                    self?.cache.invalidate(path: url.deletingLastPathComponent().path)
                }
                Task { await self?.recomputeSyncStatus() }
            }
        }
        if !skipped.isEmpty {
            let n = restores.count
            errorMessage = "Overwrote \(n) file\(n == 1 ? "" : "s"); skipped \(skipped.count) not readable as text: \(skipped.joined(separator: ", "))"
        }
        Task { await recomputeSyncStatus() }
    }

    // MARK: - Copy as Context

    /// Copy the given files' CONTENTS as one LLM-pasteable blob. If any file
    /// looks like a secret, stage a confirmation instead of copying immediately.
    func copyAsContext(urls: [URL]) {
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        if SecretDetector.sensitiveFiles(in: unique).isEmpty {
            performContextCopy(unique)
        } else {
            pendingContextCopy = unique
        }
    }

    /// Copy the current Scan triage ticked set as context.
    func copyTickedAsContext() { copyAsContext(urls: tickedURLs) }

    func confirmPendingContextCopy() {
        if let urls = pendingContextCopy { performContextCopy(urls) }
        pendingContextCopy = nil
    }

    func cancelPendingContextCopy() { pendingContextCopy = nil }

    private func performContextCopy(_ urls: [URL]) {
        let assembled = ContextAssembler.assemble(urls, format: contextFormat)
        writeToPasteboard(assembled.text)
    }

    // MARK: - Bundles

    /// Create a bundle from the current selection and open it.
    func createBundleFromSelection() {
        let paths = selectedURLs.map(\.path)
        guard !paths.isEmpty, let library else { return }
        let bundle = library.addBundle(name: "Bundle \(bundles.count + 1)", paths: paths)
        bundles = library.bundles()
        openBundle(bundle)
    }

    func addPaths(_ paths: [String], to bundle: ContextBundle) {
        guard let library else { return }
        var seen = Set<String>()
        let merged = (bundle.paths + paths).filter { seen.insert($0).inserted }
        library.setBundlePaths(merged, for: bundle)
        bundles = library.bundles()
    }

    func removePath(_ path: String, from bundle: ContextBundle) {
        guard let library else { return }
        library.setBundlePaths(bundle.paths.filter { $0 != path }, for: bundle)
        bundles = library.bundles()
    }

    func renameBundle(_ bundle: ContextBundle, to name: String) {
        guard let library else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.renameBundle(bundle, to: trimmed)
        bundles = library.bundles()
    }

    func deleteBundle(_ bundle: ContextBundle) {
        guard let library else { return }
        if activeBundle?.id == bundle.id { closeBundle() }
        library.removeBundle(bundle)
        bundles = library.bundles()
    }

    /// Show a bundle in the detail pane (supersedes any active scan).
    func openBundle(_ bundle: ContextBundle) {
        if activeScan != nil { closeScan() }
        activeBundle = bundle
    }

    func closeBundle() { activeBundle = nil }

    // MARK: - Display name

    /// The label to show for a path: user override → auto parent-folder name for
    /// ambiguous filenames → the filename itself.
    func displayName(for url: URL) -> String {
        library?.displayName(for: url.path)
            ?? DisplayName.autoName(for: url)
            ?? url.lastPathComponent
    }

    // MARK: - Selection / document

    /// Choose a file from the sidebar: highlight immediately, then load.
    func choose(_ url: URL) {
        if activeBundle != nil { closeBundle() }
        if activeScan != nil { closeScan() }
        selectedURL = url
        Task { await select(url) }
    }

    /// Select a file: load text if it's textual, else mark as non-text.
    func select(_ url: URL) async {
        selectedURL = url
        errorMessage = nil
        let kind = FileKind.detect(filename: url.lastPathComponent)
        selectedKind = kind
        let isConfig = ConfigRegistry.format(forFilename: url.lastPathComponent) != nil
        guard Self.textEditableKinds.contains(kind) || isConfig else {
            documentText = nil
            loadedText = nil
            isDirty = false
            return
        }
        do {
            let doc = try await TextDocument.load(url)
            documentText = doc.text
            loadedText = doc.text
            isDirty = false
        } catch {
            documentText = nil
            loadedText = nil
            errorMessage = "Couldn't open \(url.lastPathComponent) as text."
        }
    }

    /// Called by the editor when text changes.
    func documentTextChanged(_ newText: String) {
        documentText = newText
        isDirty = (newText != loadedText)
    }

    /// The currently-loaded on-disk text (for structured editors to parse).
    var currentText: String { documentText ?? "" }

    /// Save the open document back to disk.
    func save() {
        guard let url = selectedURL, let text = documentText, isDirty else { return }
        do {
            try TextDocument(url: url, text: text).save()
            loadedText = text
            isDirty = false
            cache.invalidate(path: url.deletingLastPathComponent().path)
        } catch {
            errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
