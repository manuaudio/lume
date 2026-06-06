import Foundation
import Observation
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

    // MARK: - Library (SwiftData-backed)

    private(set) var library: LibraryStore?
    private(set) var favorites: [Favorite] = []
    private(set) var tags: [Tag] = []
    private(set) var hiddenPaths: Set<String> = []

    // MARK: - Internals

    private var loadedText: String?
    private let files = FileService()
    /// Main-actor enumeration cache; FSEvents invalidations bump its `revision`.
    let cache = FileSystemCache()
    private var watcher: DirectoryWatcher?

    /// Kinds Lume edits as plain text in the editor (others get a viewer).
    static let textEditableKinds: Set<FileKind> = [.markdown, .env, .code]

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
    }

    // MARK: - Open folder

    /// Open a folder as the new root. Persists it for next launch.
    func openFolder(_ url: URL) {
        rootURL = url
        browseURL = url
        selectedURL = nil
        documentText = nil
        errorMessage = nil
        cache.invalidateAll()
        startWatching(url)
        Preferences.saveLastFolder(url)
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
    func navigate(to url: URL) { browseURL = url }

    /// Visible children of the current browse directory (cache-backed, filtered).
    var browseChildren: [FileNode] {
        _ = cache.revision   // observe FSEvents invalidations
        guard let browseURL else { return [] }
        let nodes = cache.children(of: browseURL, includeHidden: showBrowserHidden)
        return VisibleChildrenFilter.apply(
            nodes,
            filesOnly: filesOnly,
            isPinned: false,
            showPinnedHidden: showPinnedHidden,
            hiddenPaths: hiddenPaths,
            browseFilter: browseFilter
        )
    }

    // MARK: - Favorites (pinning)

    /// Pinned items, minus user-hidden ones unless `showPinnedHidden`.
    var visibleFavorites: [Favorite] {
        favorites.filter { showPinnedHidden || !hiddenPaths.contains($0.path) }
    }

    func isFavorite(_ url: URL) -> Bool {
        library?.isFavorite(path: url.path) ?? false
    }

    func toggleFavorite(_ node: FileNode) {
        guard let library else { return }
        if library.isFavorite(path: node.url.path) {
            library.removeFavorite(path: node.url.path)
        } else if node.isDirectory {
            library.addFavoriteFolder(path: node.url.path)
        } else {
            library.addFavorite(path: node.url.path, kind: node.kind)
        }
        refreshLibrary()
    }

    /// Whether a stored favorite is a folder (persisted via the "folder" sentinel).
    func favoriteIsFolder(_ favorite: Favorite) -> Bool {
        favorite.kindRaw == "folder"
    }

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
