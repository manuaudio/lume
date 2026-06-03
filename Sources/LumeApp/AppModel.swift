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
    var expandedPaths: Set<String> = []
    /// Multi-row selection for the sidebar `List`. Single-row behaviors
    /// (Quick Look, ←/→, open-on-select) run only when this holds exactly one id.
    var selectedRowIDs: Set<String> = []
    /// True only while ⌃ (Control) is held — drives the transient path bar.
    var pathPeek = false
    /// Drives the multi-selection "Edit Tags…" sheet (see MultiTagSheet).
    var editingTagsForSelection = false
    var browseFilter: String = ""

    // Inline editing (which row is mid-edit)
    var renamingPath: String?
    var notesOpenPath: String?

    /// Injected once from `ContentView` so toolbar/sidebar actions can reach
    /// the SwiftData store without each view re-deriving it.
    @ObservationIgnored var libraryContext: ModelContext?

    @ObservationIgnored let files: FileServicing = FileService()

    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
        showPinnedHidden = UserDefaults.standard.bool(forKey: "lume.showPinnedHidden")
        showBrowserHidden = UserDefaults.standard.bool(forKey: "lume.showBrowserHidden")
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
        guard let id = soleSelectedRowID,
              let row = SidebarRow.decode(id), !row.isDirectory else { return }
        selectedFile = row.url
    }

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
