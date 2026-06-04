import SwiftUI
import SwiftData
import Observation
import AppKit
import LumeCore

@MainActor
@Observable
final class AppModel {
    var rootFolder: URL?
    var tree: [FileNode] = []
    var selectedFile: URL?
    var activeTagFilter: String?

    // Browser
    var browseRoot: URL? {
        didSet {
            // Defense in depth: a relative/non-file URL makes
            // `Breadcrumb.segments` walk parents unbounded (31 GB CPU-kill hang),
            // so force a standardized absolute file URL before it reaches the UI.
            // Reassigning re-enters this `didSet`, but `safe` is then a fixed
            // point, so it settles in at most two cycles.
            if let r = browseRoot {
                let safe = r.isFileURL ? r.standardizedFileURL
                                       : URL(fileURLWithPath: r.path).standardizedFileURL
                if safe != r { browseRoot = safe; return }
            }
            persistBrowseRoot()
        }
    }
    var filesOnly = false { didSet { UserDefaults.standard.set(filesOnly, forKey: "lume.filesOnly") } }
    /// FAVORITES curation: when true, items hidden from Favorites are revealed
    /// (dimmed, with an un-hide affordance) instead of omitted.
    var showPinnedHidden = false { didSet { UserDefaults.standard.set(showPinnedHidden, forKey: "lume.showPinnedHidden") } }
    /// OPEN FOLDER browser: when true, Finder-hidden dotfiles (.env, .claude…)
    /// are revealed. Independent of `showPinnedHidden`.
    var showBrowserHidden = false { didSet { UserDefaults.standard.set(showBrowserHidden, forKey: "lume.showBrowserHidden") } }
    /// Pillar ①: when true, the document pane shows the collapsible tag header
    /// above the routed viewer. Persisted globally and remembered across launches
    /// (default true). Toggled by the 🏷 toolbar button and the header's ⌃ collapse.
    var showEditorTags = true { didSet { UserDefaults.standard.set(showEditorTags, forKey: "lume.showEditorTags") } }
    var expandedPaths: Set<String> = []
    /// Multi-row selection for the sidebar `List`. Single-row behaviors
    /// (Quick Look, ←/→, open-on-select) run only when this holds exactly one id.
    var selectedRowIDs: Set<String> = []
    /// The row id the most recent contiguous (⇧) keyboard extension is anchored
    /// to, and the row id that currently has keyboard focus within that range.
    /// Reset whenever a plain move/selection replaces the selection.
    @ObservationIgnored var selectionAnchorID: String?
    @ObservationIgnored var selectionFocusID: String?

    /// Flat, top-to-bottom order of the currently-visible sidebar row ids.
    /// Published by `SidebarView` each render so keyboard range math (which has
    /// no view tree) can resolve neighbors. Not observed (read on key events).
    @ObservationIgnored var orderedVisibleRowIDs: [String] = []
    /// True only while ⌃ (Control) is held — drives the transient path bar.
    var pathPeek = false
    /// Drives the multi-selection "Edit Tags…" sheet (see MultiTagSheet).
    var editingTagsForSelection = false
    var browseFilter: String = ""

    // Inline editing (which row is mid-edit)
    var renamingPath: String?
    var notesOpenPath: String?
    /// The selected file whose inline tag editor is open. nil = collapsed
    /// (tags show as read-only chips, or nothing when the file has none).
    var tagsOpenPath: String?

    /// Injected once from `ContentView` so toolbar/sidebar actions can reach
    /// the SwiftData store without each view re-deriving it.
    @ObservationIgnored var libraryContext: ModelContext?

    @ObservationIgnored let files: FileServicing = FileService()

    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
        showPinnedHidden = UserDefaults.standard.bool(forKey: "lume.showPinnedHidden")
        showBrowserHidden = UserDefaults.standard.bool(forKey: "lume.showBrowserHidden")
        // Default to shown on first run: only override the `true` default when a
        // value was explicitly persisted (object(forKey:) is nil when unset).
        if UserDefaults.standard.object(forKey: "lume.showEditorTags") != nil {
            showEditorTags = UserDefaults.standard.bool(forKey: "lume.showEditorTags")
        }
        if let p = UserDefaults.standard.string(forKey: "lume.browseRoot") {
            browseRoot = URL(fileURLWithPath: p)
        } else {
            browseRoot = FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private func persistBrowseRoot() {
        UserDefaults.standard.set(browseRoot?.path, forKey: "lume.browseRoot")
    }

    // MARK: Folder navigation

    func openFolder(_ url: URL) {
        rootFolder = url
        selectedFile = nil
        reloadTree()
    }

    func reloadTree() {
        guard let root = rootFolder else {
            tree = []
            return
        }
        tree = (try? files.enumerate(root)) ?? []
    }

    func children(of node: FileNode, includeHidden: Bool = false) -> [FileNode] {
        (try? files.enumerate(node.url, includeHidden: includeHidden)) ?? []
    }

    func children(of url: URL, includeHidden: Bool = false) -> [FileNode] {
        (try? files.enumerate(url, includeHidden: includeHidden)) ?? []
    }

    // MARK: Favorites

    func isFavorite(_ url: URL) -> Bool {
        store?.isFavorite(path: url.path) ?? false
    }

    /// Toggle favorite for a file or folder. Folders persist a sentinel kind.
    func toggleFavorite(_ url: URL, isDirectory: Bool) {
        guard let store else { return }
        let path = url.path
        if store.isFavorite(path: path) {
            store.removeFavorite(path: path)
        } else if isDirectory {
            store.addFavoriteFolder(path: path)
        } else {
            store.addFavorite(path: path, kind: FileKind.detect(filename: url.lastPathComponent))
        }
    }

    // MARK: Bookmarks (Browse aliases)

    var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }

    func isBookmarked(_ url: URL) -> Bool { store?.isBookmarked(path: url.path) ?? false }

    func toggleBookmark(_ url: URL) {
        guard let store else { return }
        if store.isBookmarked(path: url.path) {
            store.removeBookmark(path: url.path)
        } else {
            store.addBookmark(path: url.path)
        }
    }

    /// First-run setup: migrate any old bookmarks to pins, then seed default
    /// pinned locations if there are no favorites yet.
    func seedAndMigratePins() {
        guard let store else { return }
        store.migrateBookmarksToFavorites()
        guard store.favorites().isEmpty else { return }
        let fm = FileManager.default
        store.addFavoriteFolder(path: homeURL.path)
        let candidates = [
            homeURL.appendingPathComponent("Documents"),
            homeURL.appendingPathComponent("Desktop"),
            homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            store.addFavoriteFolder(path: url.path)
        }
    }

    // MARK: Browser drill navigation

    func drillInto(_ url: URL) {
        browseRoot = url
        expandedPaths.removeAll()
        browseFilter = ""
    }

    // MARK: - Multi-selection commands

    /// Write the selected paths to the clipboard as newline-joined POSIX paths
    /// (the AI hand-off) AND as file URLs, so pasting into Finder/editors that
    /// prefer file references also works. Mirrors Finder's "Copy as Pathname".
    func copyPaths() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        pb.setString(PathExport.clipboardString(for: urls), forType: .string)
    }

    /// True when every selected path is already hidden (drives the menu label).
    func selectionIsAllHidden(_ hiddenPaths: Set<String>) -> Bool {
        let urls = selectedURLs
        return !urls.isEmpty && urls.allSatisfy { hiddenPaths.contains($0.path) }
    }

    /// Hide or un-hide every selected path.
    func setHiddenForSelection(_ hidden: Bool) {
        guard let store else { return }
        store.setHidden(hidden, paths: selectedURLs.map(\.path))
    }

    /// Un-hide a single path (inline eye affordance on a dimmed row).
    func unhide(_ url: URL) {
        store?.setHidden(false, paths: [url.path])
    }

    /// Promote the first selected folder to the Open Folder region.
    func openSelectedFolder() {
        guard let folder = selectedFolderURLs.first else { return }
        drillInto(folder)
    }

    /// Remove every selected path from favorites.
    func unpinSelection() {
        guard let store else { return }
        for url in selectedURLs { store.removeFavorite(path: url.path) }
    }

    /// Apply a comma-separated tag string to every selected path, preserving
    /// each path's existing info/displayName (read via `meta(for:)`).
    func applyTagsToSelection(_ tagString: String) {
        guard let store else { return }
        let names = tagString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for url in selectedURLs {
            let existing = store.meta(for: url.path)
            store.setMeta(path: url.path,
                          info: existing?.info ?? "",
                          tagNames: names,
                          displayName: existing?.displayName ?? "")
        }
    }

    /// Apply an explicit list of tag names to every selected path (replaces each
    /// path's tags). Used by the token-field multi-edit sheet.
    func applyTagNamesToSelection(_ names: [String]) {
        applyTagsToSelection(names.joined(separator: ","))
    }

    func toggleExpanded(_ url: URL) {
        if expandedPaths.contains(url.path) { expandedPaths.remove(url.path) }
        else { expandedPaths.insert(url.path) }
    }

    /// `cd ..` — stops at filesystem root.
    func drillUp() {
        guard let root = browseRoot else { return }
        let parent = root.deletingLastPathComponent()
        if parent.path != root.path { browseRoot = parent }
    }

    // MARK: Pins (unified — a pin IS a favorite, file or folder)

    func isPinned(_ url: URL) -> Bool { isFavorite(url) }

    func togglePin(_ url: URL, isDirectory: Bool) {
        toggleFavorite(url, isDirectory: isDirectory)
    }

    /// Open a folder (and optionally select a file) from environment variables,
    /// so Lume can be launched pointed at a location:
    ///   LUME_OPEN_FOLDER=/path/to/dir  LUME_OPEN_FILE=/path/to/dir/file.md
    func applyLaunchEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let folder = env["LUME_OPEN_FOLDER"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder)
            openFolder(url)
            browseRoot = url
        }
        if let file = env["LUME_OPEN_FILE"], !file.isEmpty {
            selectedFile = URL(fileURLWithPath: file)
        }
    }

    // MARK: File reads (iCloud-aware)

    /// Read a file's text without touching iCloud download state. Safe and
    /// instant if the file is already local; returns "" for an evicted
    /// placeholder (callers should prefer `readFile(_:completion:)`).
    func readFileNow(_ url: URL) -> String {
        (try? files.read(url)) ?? ""
    }

    /// Read a file's text, first making sure an evicted iCloud placeholder is
    /// materialized on disk. Never blocks the calling thread; `completion` is
    /// invoked on the main actor once the bytes are available (or after a brief
    /// download timeout).
    func readFile(_ url: URL, completion: @escaping (String) -> Void) {
        ICloudCoordinator.ensureDownloaded(url) { [weak self] in
            completion(self?.readFileNow(url) ?? "")
        }
    }

    func write(_ text: String, to url: URL) {
        try? files.write(text, to: url)
    }

    // MARK: Selected-row helpers (for keyboard commands)

    /// The sole selected row id, or nil when zero or multiple rows are selected.
    /// Single-row keyboard/open behaviors gate on this.
    var soleSelectedRowID: String? {
        selectedRowIDs.count == 1 ? selectedRowIDs.first : nil
    }

    /// The URL of the sole selected row (file or folder), if exactly one.
    var selectedRowURL: URL? {
        guard let id = soleSelectedRowID else { return nil }
        return SidebarRow.decode(id)?.url
    }

    /// All selected rows decoded to file URLs, in sidebar (sorted-id) order.
    /// Every multi-item command consumes this.
    var selectedURLs: [URL] {
        selectedRowIDs.sorted().compactMap { SidebarRow.decode($0)?.url }
    }

    /// The section the current multi-selection belongs to, if uniform.
    /// (Mixed pinned+browser selections fall back to `.browser` for the action
    /// set — pin/open semantics still make sense.) Derived from row id prefixes.
    var selectionSection: SidebarSection {
        let sections = Set(selectedRowIDs.compactMap { $0.split(separator: "|").first.map(String.init) })
        return sections == ["pinned"] ? .pinned : .browser
    }

    /// True when every selected path is already pinned (drives Pin vs Unpin).
    var selectionIsAllPinned: Bool {
        let urls = selectedURLs
        return !urls.isEmpty && urls.allSatisfy { isPinned($0) }
    }

    /// Pin every selected path that isn't already pinned (Browse action-bar Pin).
    func pinSelection() {
        guard let store else { return }
        for id in selectedRowIDs {
            guard let row = SidebarRow.decode(id), !store.isFavorite(path: row.url.path) else { continue }
            if row.isDirectory { store.addFavoriteFolder(path: row.url.path) }
            else { store.addFavorite(path: row.url.path,
                                     kind: FileKind.detect(filename: row.url.lastPathComponent)) }
        }
    }

    /// Selected rows that are directories, in sidebar order (for Open).
    var selectedFolderURLs: [URL] {
        selectedRowIDs.sorted().compactMap {
            guard let row = SidebarRow.decode($0), row.isDirectory else { return nil }
            return row.url
        }
    }

    private var selectedRowIsDirectory: Bool {
        guard let id = soleSelectedRowID else { return false }
        return SidebarRow.decode(id)?.isDirectory ?? false
    }

    /// Open a file in the document view only when exactly one file row is
    /// selected, so extending a multi-selection doesn't thrash the document view.
    func openIfSingleFileSelected() {
        if let id = soleSelectedRowID {
            // A fresh single selection becomes the new anchor for ⇧-extends.
            selectionAnchorID = id
            selectionFocusID = id
        }
        guard let id = soleSelectedRowID,
              let row = SidebarRow.decode(id), !row.isDirectory else { return }
        selectedFile = row.url
    }

    /// ⌘A — select every visible row. Anchor on the current sole selection (so a
    /// following ⇧↑/⇧↓ extends from where the user was, like Finder) and fall back
    /// to the first row when there was no single prior selection.
    func selectAllVisibleRows() {
        // Capture the prior sole selection BEFORE replacing selectedRowIDs —
        // afterwards soleSelectedRowID is nil whenever there's >1 visible row.
        let priorSole = soleSelectedRowID
        selectedRowIDs = RowSelection.all(in: orderedVisibleRowIDs)
        selectionAnchorID = priorSole ?? orderedVisibleRowIDs.first
        selectionFocusID = orderedVisibleRowIDs.last
    }

    /// ↑ / ↓ (no modifier) — move the single selection one row in the flat
    /// visible order, replacing it (Finder plain-arrow). Re-anchors so a later
    /// ⇧-extend starts fresh from the moved-to row. Wired explicitly because
    /// native arrow traversal across this multi-section, recursively-rendered
    /// List is unreliable.
    func moveSelection(by step: Int) {
        let current = soleSelectedRowID ?? selectionFocusID ?? selectionAnchorID
        guard let r = RowSelection.move(from: current, in: orderedVisibleRowIDs, by: step) else { return }
        selectedRowIDs = r.selection
        // Belt-and-suspenders: `openIfSingleFileSelected` (driven by the
        // onChange(selectedRowIDs) observer) authoritatively re-sets the anchor
        // and focus to this new sole selection. We set them here too so the values
        // are already correct if a synchronous ⇧-extend reads them before the
        // observer fires.
        selectionAnchorID = r.anchor
        selectionFocusID = r.anchor
    }

    /// ⇧↑ / ⇧↓ — extend a contiguous selection from the anchor. Seeds the anchor
    /// from the current sole selection on first use.
    ///
    /// LIMITATION (not full Finder parity): a native mouse ⇧-click mutates
    /// `selectedRowIDs` directly, bypassing `selectionAnchorID`/`selectionFocusID`.
    /// We mitigate the most common case below: if the live selection is a single
    /// contiguous run but our `selectionFocusID` is stale (not at either end of
    /// that run), we re-derive the focus as the run endpoint FARTHER from the
    /// anchor, so the next keyboard ⇧-arrow grows the range from the visible edge
    /// instead of collapsing it. Non-contiguous (⌘-clicked) selections fall back
    /// to the stored anchor/focus unchanged — keyboard extend then re-grows a
    /// contiguous range from the anchor, which is acceptable.
    func extendSelection(by step: Int) {
        if selectionAnchorID == nil { selectionAnchorID = soleSelectedRowID ?? orderedVisibleRowIDs.first }
        if selectionFocusID == nil { selectionFocusID = selectionAnchorID }

        // Recover from a stale focus left by a native mouse ⇧-click.
        if let endpoints = RowSelection.contiguousRunEndpoints(of: selectedRowIDs,
                                                               in: orderedVisibleRowIDs) {
            let focusIsEndpoint = selectionFocusID == endpoints.low || selectionFocusID == endpoints.high
            if !focusIsEndpoint {
                // Keep (or adopt) an anchor that sits at a run endpoint; pick the
                // far endpoint as the new focus so we grow outward.
                if selectionAnchorID == endpoints.high {
                    selectionFocusID = endpoints.low
                } else {
                    // anchor is endpoints.low, or stale → anchor on low, focus high.
                    selectionAnchorID = endpoints.low
                    selectionFocusID = endpoints.high
                }
            }
        }

        guard let anchor = selectionAnchorID, let focus = selectionFocusID,
              let r = RowSelection.extend(anchor: anchor, focus: focus,
                                          in: orderedVisibleRowIDs, by: step) else { return }
        selectedRowIDs = r.selection
        selectionFocusID = r.focus
    }

    /// ⏎ — open the sole selected file, or drill into the sole selected folder.
    /// Reuses the existing single-row open/drill behavior.
    func activateSelectedRow() { openOrDrillSelected() }

    func renameSelected() { renamingPath = selectedRowURL?.path }

    func pinSelected() {
        guard let url = selectedRowURL else { return }
        togglePin(url, isDirectory: selectedRowIsDirectory)
    }

    func openOrDrillSelected() {
        guard let url = selectedRowURL else { return }
        if selectedRowIsDirectory { drillInto(url) } else { selectedFile = url }
    }

    // MARK: Derived

    var selectedKind: FileKind? {
        selectedFile.map { FileKind.detect(filename: $0.lastPathComponent) }
    }

    var store: LibraryStore? {
        libraryContext.map { LibraryStore(context: $0) }
    }
}
