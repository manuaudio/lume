import SwiftUI
import SwiftData
import Observation
import AppKit
import LumeCore

/// One trashed item's round-trip: where it landed in the Trash (`from`) and the
/// original path to restore it to (`to`). Sendable so undo closures can capture
/// it without crossing actor-isolation rules.
struct TrashRestore: Sendable {
    let from: URL
    let to: URL
}

@MainActor
@Observable
final class AppModel {
    var rootFolder: URL?
    var tree: [FileNode] = []
    var selectedFile: URL?

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
            restartWatcher()
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

    /// Phase 3: the "vibecoder" structured config editor. A global default
    /// (persisted) plus per-file overrides (persisted), so any config file can be
    /// flipped between the structured form and raw source and remembered.
    var configStructuredByDefault = true {
        didSet { UserDefaults.standard.set(configStructuredByDefault, forKey: "lume.configStructuredDefault") }
    }
    private var configViewOverrides: [String: Bool] = [:] {
        didSet { UserDefaults.standard.set(configViewOverrides, forKey: "lume.configViewOverrides") }
    }

    /// Whether the structured editor (vs raw source) should show for `path`.
    func configShowsStructured(forPath path: String) -> Bool {
        configViewOverrides[path] ?? configStructuredByDefault
    }

    /// Remember a per-file structured/raw choice.
    func setConfigShowsStructured(_ structured: Bool, forPath path: String) {
        configViewOverrides[path] = structured
    }

    var expandedPaths: Set<String> = []

    /// Tag NAMES whose GROUP is currently expanded in the GROUPS region. Distinct
    /// from `expandedPaths` (real folders) — a group has no disk folder.
    var expandedGroups: Set<String> = []

    /// path → custom display name (non-empty only). Stable @Observable state,
    /// updated ONCE by `MetaIndexLoader` from the all-metadata @Query — never
    /// rebuilt per render. Rows look up their own scalar (`displayName(forPath:)`)
    /// so editing one file re-renders only that row, not the whole tree.
    var displayNames: [String: String] = [:]
    /// Paths flagged hidden. Same isolation rationale as `displayNames`.
    var hiddenPaths: Set<String> = []

    /// Per-row scalar lookups. Rows depend on these (not the whole dict), so
    /// SwiftUI skips re-rendering rows whose scalar is unchanged.
    func displayName(forPath path: String) -> String? { displayNames[path] }
    func isHidden(_ path: String) -> Bool { hiddenPaths.contains(path) }

    /// Replace the metadata index. Called by the isolated `MetaIndexLoader` leaf
    /// view on appear and whenever the all-metadata @Query changes — the only
    /// place the expensive full-table fetch touches the model.
    func updateMetaIndex(displayNames: [String: String], hiddenPaths: Set<String>) {
        if self.displayNames != displayNames { self.displayNames = displayNames }
        if self.hiddenPaths != hiddenPaths { self.hiddenPaths = hiddenPaths }
    }
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

    /// Caches directory enumeration so re-rendering the tree never hits the disk.
    /// `@ObservationIgnored` on the reference itself (the model doesn't change
    /// identity); views observe the cache's `revision` via `fileSystemRevision`.
    @ObservationIgnored private let cache = FileSystemCache()

    /// The single live filesystem watcher on `browseRoot`. Replaced (old one
    /// stopped) whenever the browse root changes; see `restartWatcher()`.
    @ObservationIgnored private var watcher: DirectoryWatcher?

    /// External-change ticker: the cache's `revision`, exposed so the sidebar
    /// tree can `.onChange` on it and re-read invalidated directories after a
    /// Finder/other-app edit.
    var fileSystemRevision: Int { cache.revision }

    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
        showPinnedHidden = UserDefaults.standard.bool(forKey: "lume.showPinnedHidden")
        showBrowserHidden = UserDefaults.standard.bool(forKey: "lume.showBrowserHidden")
        // Default to shown on first run: only override the `true` default when a
        // value was explicitly persisted (object(forKey:) is nil when unset).
        if UserDefaults.standard.object(forKey: "lume.showEditorTags") != nil {
            showEditorTags = UserDefaults.standard.bool(forKey: "lume.showEditorTags")
        }
        if UserDefaults.standard.object(forKey: "lume.configStructuredDefault") != nil {
            configStructuredByDefault = UserDefaults.standard.bool(forKey: "lume.configStructuredDefault")
        }
        configViewOverrides = (UserDefaults.standard.dictionary(forKey: "lume.configViewOverrides") as? [String: Bool]) ?? [:]
        // Re-establish access to the last explicitly-opened folder (security-scoped
        // bookmark) before restoring the browse root, so a sandboxed relaunch can
        // still read it. No-op / bonus when unsandboxed.
        _ = SecurityScopedAccess.resolve(key: "lume.rootBookmark")
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
        // Persist access to this user-granted folder so it (and its subtree)
        // remains reachable on the next launch under the App Sandbox. Harmless
        // when unsandboxed. The grant transitively covers children, so this is
        // the access anchor for Browse mode too.
        SecurityScopedAccess.store(url, key: "lume.rootBookmark")
        SecurityScopedAccess.beginAccess(url)
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
        cache.children(of: node.url, includeHidden: includeHidden)
    }

    func children(of url: URL, includeHidden: Bool = false) -> [FileNode] {
        cache.children(of: url, includeHidden: includeHidden)
    }

    /// Whether `url`'s children are still cached. A directory drops out of the
    /// cache only when FSEvents reports it changed, so a mounted `FileTreeView`
    /// uses this to skip re-reading itself on filesystem ticks that didn't touch
    /// it — one edit no longer re-runs every view in the expanded tree.
    func isDirectoryCached(_ url: URL, includeHidden: Bool) -> Bool {
        cache.isCached(path: url.path, includeHidden: includeHidden)
    }

    /// (Re)start the filesystem watcher on the current `browseRoot`. Stops any
    /// previous watcher first so only one stream is ever live. FSEvents change
    /// events invalidate the affected directories in the cache (bumping its
    /// `revision`), which the sidebar observes via `fileSystemRevision`.
    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        guard let root = browseRoot else { return }
        watcher = DirectoryWatcher(root: root) { [weak self] changed in
            guard let self else { return }
            for path in changed { self.cache.invalidate(path: path) }
        }
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

    // NOTE: the GROUPS redesign removed tag-filtering, so nothing in the app calls
    // `RowSelection.revalidate(...)` anymore. The pure helper (and its tests) are
    // kept in SelectionKit as harmless, still-passing dead code rather than churn
    // the selection suite; reintroduce a caller if filtering ever returns.

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

    /// The tag names COMMON to every selected file (set intersection of each
    /// file's current tags), in stable sorted order. Seeds the bulk tag editor so
    /// hitting Apply with replace-semantics shows the current shared state instead
    /// of an empty field (which would wipe all tags). Files with no meta contribute
    /// an empty set, so any such file empties the intersection.
    func commonTagNamesInSelection() -> [String] {
        guard let store else { return [] }
        let urls = selectedURLs
        guard let first = urls.first else { return [] }
        var common = Set(store.meta(for: first.path)?.tags.map(\.name) ?? [])
        for url in urls.dropFirst() {
            common.formIntersection(store.meta(for: url.path)?.tags.map(\.name) ?? [])
            if common.isEmpty { break }
        }
        return common.sorted()
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

    /// Pin every dropped URL that isn't already a favorite (drag-from-browser to
    /// the FAVORITES region). Resolves each URL's directory-ness from disk.
    func pinDropped(_ urls: [URL]) {
        for url in urls where !isPinned(url) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            togglePin(url, isDirectory: isDir)
        }
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

    /// Pending debounced document writes, keyed by path. Keyed (not a single
    /// token) so switching files never cancels another file's in-flight save.
    @ObservationIgnored private var pendingWrites: [String: Task<Void, Never>] = [:]

    /// Persist editor text. The CodeMirror change event is already JS-debounced;
    /// here we additionally coalesce per-file and perform the disk write OFF the
    /// main actor, so typing never blocks the UI on atomic file I/O.
    func write(_ text: String, to url: URL) {
        let path = url.path
        pendingWrites[path]?.cancel()
        pendingWrites[path] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await Self.persist(text, to: url)
            self?.pendingWrites[path] = nil
        }
    }

    /// The actual disk write, off the main actor (nonisolated async runs on the
    /// cooperative pool). Atomic so a crash mid-write can't truncate the file.
    private nonisolated static func persist(_ text: String, to url: URL) async {
        try? text.write(to: url, atomically: true, encoding: .utf8)
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

    /// True when at least one selected row is a REAL file/folder (decodable via
    /// `SidebarRow`). Group header/file rows decode to nil here, so an all-group
    /// selection is false — used to suppress Pin/Hide, which would no-op on it.
    var selectionHasRealItems: Bool {
        selectedRowIDs.contains { SidebarRow.decode($0) != nil }
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

    /// A mouse click on a sidebar row, honoring ⌘ (toggle) and ⇧ (contiguous
    /// range) like Finder, and falling back to select-and-activate for a plain
    /// click. This restores explicit single-click behavior: native
    /// `List(selection:)` was NOT delivering single clicks to these rows (the
    /// double-click `.onTapGesture` shadowed it), so a single click did nothing —
    /// a regression. A plain click now sole-selects the row and activates it
    /// (folder → select only (double-click drills in); file → show its content),
    /// mirroring the original single-click design.
    func clickRow(id rowID: String, isDirectory: Bool, url: URL,
                  command: Bool, shift: Bool) {
        let r = RowSelection.click(target: rowID, current: selectedRowIDs,
                                   anchor: selectionAnchorID, in: orderedVisibleRowIDs,
                                   command: command, shift: shift)
        selectedRowIDs = r.selection
        selectionAnchorID = r.anchor
        selectionFocusID = r.focus
        // Activate only on a plain click (no modifier). GROUPS redesign: a single
        // click on a real FOLDER (pinned or browser) now ONLY selects — it no
        // longer toggles inline expansion (double-click drills into the browser
        // instead). A single click on a FILE still opens it. Group headers /
        // group files route through their own gestures in GroupsSection, not here.
        guard !command, !shift else { return }
        if !isDirectory { selectedFile = url }
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

    /// ← on a collapsed folder / file: jump to the parent folder row when it's
    /// visible in the tree (Finder's Left-arrow traversal). Returns whether it
    /// moved, so the caller can fall through to `.ignored` at the root.
    func selectParentRow(ofRowID id: String) -> Bool {
        // GROUP ids (`group|g|name`, `groupfile|f|name|path`) don't share the
        // `section|d-or-f|path` grammar — splitting them positionally yields a
        // bogus "path". A group header has no parent row; a group file has no
        // parent-folder row in the GROUPS region. Skip both.
        if GroupRowID.decode(id) != nil { return false }
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let section = String(parts[0])
        let parent = URL(fileURLWithPath: String(parts[2])).deletingLastPathComponent()
        let parentID = "\(section)|d|\(parent.path)"
        guard orderedVisibleRowIDs.contains(parentID) else { return false }
        selectedRowIDs = [parentID]
        selectionAnchorID = parentID
        selectionFocusID = parentID
        return true
    }

    // MARK: Type-to-select (Finder typeahead)

    @ObservationIgnored private var typeaheadBuffer = ""
    @ObservationIgnored private var typeaheadReset: Task<Void, Never>?

    /// Accumulate a typed character and jump to the first visible row whose name
    /// starts with the buffer, resetting the buffer after a short idle (Finder
    /// type-to-select). Keyed off the rendered `orderedVisibleRowIDs` so the match
    /// order is exactly what the user sees.
    func typeaheadAppend(_ character: Character) {
        typeaheadReset?.cancel()
        typeaheadBuffer.append(character)
        selectByTypeahead(typeaheadBuffer)
        typeaheadReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            self?.typeaheadBuffer = ""
        }
    }

    private func selectByTypeahead(_ prefix: String) {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return }
        for id in orderedVisibleRowIDs {
            // Resolve each row's typeahead name and (for files) its openable path,
            // handling the GROUP id grammar separately from the positional
            // `section|d-or-f|path` grammar so a `groupfile|f|tag|/path` id never
            // gets mis-split into a bogus path.
            let name: String
            var openPath: String?
            switch GroupRowID.decode(id) {
            case .header(let tagName):
                name = tagName.lowercased()            // header: match the tag name, never open
            case .file(_, let path):
                name = (displayNames[path] ?? (path as NSString).lastPathComponent).lowercased()
                openPath = path
            case nil:
                let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let path = String(parts[2])
                name = (displayNames[path] ?? (path as NSString).lastPathComponent).lowercased()
                if parts[1] == "f" { openPath = path }
            }
            guard name.hasPrefix(needle) else { continue }
            selectedRowIDs = [id]
            selectionAnchorID = id
            selectionFocusID = id
            if let openPath { selectedFile = URL(fileURLWithPath: openPath) }
            return
        }
    }

    // MARK: File operations (New Folder · Move to Trash · Duplicate, with Undo)

    /// The focused window's UndoManager, set by the sidebar on appear so file
    /// operations register on the window's undo stack (⌘Z / ⌘⇧Z).
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Create a new untitled folder in `parent` (defaults to the browse root),
    /// reveal it, and start an inline rename. Undo trashes it.
    func newFolder(in parent: URL? = nil) {
        guard let dir = parent ?? browseRoot else { return }
        let url = FileOps.uniqueChild(in: dir, base: "untitled folder")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch { return }
        cache.invalidate(path: dir.path)
        expandedPaths.insert(dir.path)
        renamingPath = url.path
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.trash([url]) }
        }
        undoManager?.setActionName("New Folder")
    }

    /// Move the current selection (or an explicit `urls`) to the Trash. Recoverable
    /// (it's the Trash, not a delete); Undo restores the exact items.
    func trash(_ urls: [URL]? = nil) {
        let targets = urls ?? selectedURLs
        guard !targets.isEmpty else { return }
        var restores: [TrashRestore] = []
        for url in targets {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? { restores.append(TrashRestore(from: trashed, to: url)) }
            } catch { /* skip items that can't be trashed (e.g. permission) */ }
        }
        guard !restores.isEmpty else { return }
        for url in targets { cache.invalidate(path: url.deletingLastPathComponent().path) }
        // Drop trashed rows from selection / the open document.
        if let sel = selectedFile, targets.contains(sel) { selectedFile = nil }
        selectedRowIDs = selectedRowIDs.filter { id in
            guard let u = SidebarRow.decode(id)?.url else { return true }
            return !targets.contains(u)
        }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreTrashed(restores) }
        }
        undoManager?.setActionName(targets.count == 1 ? "Move to Trash"
                                                      : "Move \(targets.count) Items to Trash")
    }

    /// Undo of `trash`: move each item back from the Trash to its original path.
    /// Re-registers `trash` so redo (⌘⇧Z) works.
    func restoreTrashed(_ restores: [TrashRestore]) {
        var redo: [URL] = []
        for r in restores {
            do { try FileManager.default.moveItem(at: r.from, to: r.to); redo.append(r.to) }
            catch { /* original location gone — skip */ }
        }
        for r in restores { cache.invalidate(path: r.to.deletingLastPathComponent().path) }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.trash(redo) }
        }
        undoManager?.setActionName("Move to Trash")
    }

    /// Duplicate each selected item (or an explicit `url`) next to itself as
    /// "<name> copy". Undo trashes the copies.
    func duplicate(_ url: URL? = nil) {
        let sources = url.map { [$0] } ?? selectedURLs
        guard !sources.isEmpty else { return }
        var copies: [URL] = []
        for src in sources {
            let dest = FileOps.duplicateURL(for: src)
            do { try FileManager.default.copyItem(at: src, to: dest); copies.append(dest) }
            catch { /* skip on failure */ }
        }
        guard !copies.isEmpty else { return }
        for src in sources { cache.invalidate(path: src.deletingLastPathComponent().path) }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.trash(copies) }
        }
        undoManager?.setActionName(copies.count == 1 ? "Duplicate" : "Duplicate \(copies.count) Items")
    }

    // MARK: - Groups (tag-driven navigator)

    /// Toggle a group's expansion in the GROUPS region (double-click a group).
    func toggleGroupExpanded(_ tagName: String) {
        if expandedGroups.contains(tagName) { expandedGroups.remove(tagName) }
        else { expandedGroups.insert(tagName) }
    }

    /// Group membership cache: tag name → its file paths, already sorted by
    /// effective display name. Rebuilt ONCE by `MetaIndexLoader` from the
    /// all-metadata @Query (which observes FileMeta relationship changes reliably),
    /// so renders/keyboard-order never hit a per-tag SwiftData fetch+sort.
    var groupFilePaths: [String: [String]] = [:]

    /// Replace the group-membership cache (called by `MetaIndexLoader`).
    func updateGroupFilePaths(_ map: [String: [String]]) {
        if groupFilePaths != map { groupFilePaths = map }
    }

    /// The file paths in a group, sorted by effective display name (override →
    /// filename), path tie-broken. Drives both the rendered rows and the flat
    /// keyboard order, so they always agree. Cache-backed (see `groupFilePaths`) —
    /// no per-render SwiftData fetch.
    func sortedGroupFilePaths(forTagNamed name: String) -> [String] {
        groupFilePaths[name] ?? []
    }

    /// Revalidate selection + expanded state after a group is DELETED. The open
    /// document (`selectedFile`) is left alone — it's a real file still on disk.
    func handleGroupDeleted(_ name: String) {
        let r = GroupSelection.afterDelete(name: name,
                                           selection: selectedRowIDs,
                                           anchor: selectionAnchorID,
                                           focus: selectionFocusID,
                                           expandedGroups: expandedGroups)
        selectedRowIDs = r.selection
        selectionAnchorID = r.anchor
        selectionFocusID = r.focus
        expandedGroups = r.expandedGroups
    }

    /// Revalidate selection + expanded state after a group is RENAMED `old`→`new`
    /// (possibly merged into an existing `new`), rewriting embedded ids so the
    /// selection and the renamed group's expansion survive.
    func handleGroupRenamed(from old: String, to new: String) {
        let r = GroupSelection.afterRename(old: old, new: new,
                                           selection: selectedRowIDs,
                                           anchor: selectionAnchorID,
                                           focus: selectionFocusID,
                                           expandedGroups: expandedGroups)
        selectedRowIDs = r.selection
        selectionAnchorID = r.anchor
        selectionFocusID = r.focus
        expandedGroups = r.expandedGroups
    }

    /// Revalidate selection after ONE file is REMOVED from ONE group.
    func handleRemovedFromGroup(path: String, tagNamed name: String) {
        let r = GroupSelection.afterRemove(path: path, name: name,
                                           selection: selectedRowIDs,
                                           anchor: selectionAnchorID,
                                           focus: selectionFocusID)
        selectedRowIDs = r.selection
        selectionAnchorID = r.anchor
        selectionFocusID = r.focus
    }

    /// Create a new, empty, persistent group (the ＋ New Group affordance) and
    /// expand it so it's the obvious current drag/tag target.
    func createGroup(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let store else { return }
        store.createEmptyTag(named: name)
        expandedGroups.insert(name)
    }

    /// Drag-to-tag: add `tagName` to every dropped file's metadata, preserving its
    /// existing info/displayName/other tags. Folders dropped onto a group are
    /// ignored (groups hold files). Creates the tag if it didn't exist.
    func tag(_ urls: [URL], withTagNamed tagName: String) {
        guard let store else { return }
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDir else { continue }
            let existing = store.meta(for: url.path)
            var names = existing?.tags.map(\.name) ?? []
            guard !names.contains(tagName) else { continue }
            names.append(tagName)
            store.setMeta(path: url.path,
                          info: existing?.info ?? "",
                          tagNames: names,
                          displayName: existing?.displayName ?? "")
        }
    }

    /// Remove ONE tag from ONE file (GROUPS "Remove from {group}"). The file stays
    /// on disk and in its other groups; the (possibly now-empty) group persists.
    func removeFromGroup(path: String, tagNamed tagName: String) {
        store?.removeTag(named: tagName, fromPath: path)
    }

    /// Copy every file path in a group to the clipboard, newline-joined absolute
    /// POSIX paths (the AI hand-off), AND as file URLs (Finder/editor paste).
    /// Order matches the group's rendered order.
    func copyPaths(forGroupNamed tagName: String) {
        let urls = sortedGroupFilePaths(forTagNamed: tagName).map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        pb.setString(PathExport.clipboardString(for: urls), forType: .string)
    }

    // MARK: Derived

    var selectedKind: FileKind? {
        selectedFile.map { FileKind.detect(filename: $0.lastPathComponent) }
    }

    var store: LibraryStore? {
        libraryContext.map { LibraryStore(context: $0) }
    }
}
