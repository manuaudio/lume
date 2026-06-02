import SwiftUI
import SwiftData
import Observation
import LumeCore

@MainActor
@Observable
final class AppModel {
    var rootFolder: URL?
    var tree: [FileNode] = []
    var selectedFile: URL?
    var activeTagFilter: String?

    // Browser
    var browseRoot: URL? { didSet { persistBrowseRoot() } }
    var filesOnly = false { didSet { UserDefaults.standard.set(filesOnly, forKey: "lume.filesOnly") } }
    var expandedPaths: Set<String> = []
    var selectedRowID: String?

    // Inline editing (which row is mid-edit)
    var renamingPath: String?
    var notesOpenPath: String?

    /// Injected once from `ContentView` so toolbar/sidebar actions can reach
    /// the SwiftData store without each view re-deriving it.
    @ObservationIgnored var libraryContext: ModelContext?

    @ObservationIgnored let files: FileServicing = FileService()

    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
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

    func children(of node: FileNode) -> [FileNode] {
        (try? files.enumerate(node.url)) ?? []
    }

    func children(of url: URL) -> [FileNode] {
        (try? files.enumerate(url)) ?? []
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

    /// Seed Finder-style starting locations the first run, so Browse can reach
    /// the whole filesystem, not just one opened folder.
    func seedDefaultBookmarksIfNeeded() {
        guard let store, store.bookmarks().isEmpty else { return }
        let fm = FileManager.default
        store.addBookmark(path: homeURL.path)
        let candidates = [
            homeURL.appendingPathComponent("Documents"),
            homeURL.appendingPathComponent("Desktop"),
            homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            store.addBookmark(path: url.path)
        }
    }

    // MARK: Browser drill navigation

    func drillInto(_ url: URL) {
        browseRoot = url
        expandedPaths.removeAll()
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

    // MARK: Derived

    var selectedKind: FileKind? {
        selectedFile.map { FileKind.detect(filename: $0.lastPathComponent) }
    }

    var store: LibraryStore? {
        libraryContext.map { LibraryStore(context: $0) }
    }
}
