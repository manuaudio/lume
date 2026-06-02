import SwiftUI
import SwiftData
import Observation
import LumeCore

/// Observable app state shared across the three panes.
@MainActor
@Observable
final class AppModel {
    var rootFolder: URL?
    var tree: [FileNode] = []
    var selectedFile: URL?
    var showInfoPanel = true
    var activeTagFilter: String?

    /// Injected once from `ContentView` so toolbar/sidebar actions can reach
    /// the SwiftData store without each view re-deriving it.
    @ObservationIgnored var libraryContext: ModelContext?

    @ObservationIgnored let files: FileServicing = FileService()

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

    // MARK: File reads (iCloud-aware)

    /// Read a file's text, first making sure an evicted iCloud placeholder is
    /// materialized on disk.
    func readFile(_ url: URL) -> String {
        ICloudCoordinator.ensureDownloaded(url)
        return (try? files.read(url)) ?? ""
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
