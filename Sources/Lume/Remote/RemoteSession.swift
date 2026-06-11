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
        guard !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            children[path] = try await source.list(path, includeHidden: false)
        } catch {
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
        rootPath = path
        expanded.removeAll()
        children.removeAll()
        await loadChildren(of: path)
    }
}
