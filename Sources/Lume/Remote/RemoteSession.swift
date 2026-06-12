import Foundation
import Observation
import LumeKit

/// One live remote session: its backend connection, file source, and the
/// remote tree's UI state (root, expansion, lazily-loaded children).
@MainActor
@Observable
final class RemoteSession {
    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let connection: any RemoteConnection
    let source: any FileSource

    var phase: Phase = .connecting
    /// The directory the tree is rooted at (resolved to absolute on connect).
    var rootPath: String = "/"
    /// Lazily-loaded children per directory path; missing key = not loaded yet.
    private(set) var children: [String: [ResourceNode]] = [:]
    var expanded: Set<String> = []
    /// In-flight loads (guards double-fetch from row `.task` + toggleExpand).
    @ObservationIgnored private var loading: Set<String> = []
    /// Bumped by reroot: in-flight listings from a previous root/branch are
    /// discarded instead of landing in the fresh tree.
    @ObservationIgnored private var treeGeneration = 0
    /// Last non-fatal listing error (shown as a notice by the tree view).
    var lastError: String?

    var sourceID: SourceID { connection.sourceID }
    var displayName: String { connection.displayName }

    init(connection: any RemoteConnection, source: any FileSource) {
        self.connection = connection
        self.source = source
    }

    func connect() async {
        phase = .connecting
        do {
            rootPath = try await connection.connect()
            phase = .ready
            await loadChildren(of: rootPath)
        } catch {
            phase = .failed(connection.userMessage(for: error))
        }
    }

    func disconnect() async {
        await connection.disconnect()
    }

    func userMessage(for error: Error) -> String {
        connection.userMessage(for: error)
    }

    func loadChildren(of path: String) async {
        // Key the in-flight guard by generation: a reroot must be able to
        // re-list a path whose pre-reroot load is still in flight.
        let key = "\(treeGeneration):\(path)"
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let generation = treeGeneration
        do {
            let nodes = try await source.list(path, includeHidden: false)
            guard generation == treeGeneration else { return }   // re-rooted mid-flight
            children[path] = nodes
        } catch {
            guard generation == treeGeneration else { return }
            children[path] = []
            lastError = connection.userMessage(for: error)
        }
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil {
                Task { await loadChildren(of: path) }
            }
        }
    }

    /// Re-root the tree (go-to-path on a directory).
    func reroot(to path: String) async {
        treeGeneration += 1
        rootPath = path
        expanded.removeAll()
        children.removeAll()
        await loadChildren(of: path)
    }
}
