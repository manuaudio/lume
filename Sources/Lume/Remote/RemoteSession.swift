import Foundation
import Observation
import LumeKit

/// One live SSH connection: its transport, file source, and the remote tree's
/// UI state (root, expansion, lazily-loaded children).
@MainActor
@Observable
final class RemoteSession {
    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let host: SSHHost
    let transport: SSHTransport
    let source: SSHFileSource

    var phase: Phase = .connecting
    /// The directory the tree is rooted at (resolved to absolute on connect).
    var rootPath: String
    /// Lazily-loaded children per directory path; missing key = not loaded yet.
    private(set) var children: [String: [ResourceNode]] = [:]
    var expanded: Set<String> = []
    /// In-flight loads (guards double-fetch from row `.task` + toggleExpand).
    @ObservationIgnored private var loading: Set<String> = []
    /// Last non-fatal listing error (shown as a notice by the tree view).
    var lastError: String?

    init(host: SSHHost, startPath: String?) {
        self.host = host
        let transport = SSHTransport(host: host)
        self.transport = transport
        self.source = SSHFileSource(host: host, transport: transport)
        self.rootPath = startPath ?? "."
    }

    func connect() async {
        phase = .connecting
        do {
            try await transport.connect()
            if !rootPath.hasPrefix("/") {
                rootPath = try await source.realpath(rootPath)   // "." → home dir
            }
            phase = .ready
            await loadChildren(of: rootPath)
        } catch {
            phase = .failed((error as? SSHError)?.userMessage ?? error.localizedDescription)
        }
    }

    func loadChildren(of path: String) async {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            children[path] = try await source.list(path, includeHidden: false)
        } catch {
            children[path] = []
            lastError = (error as? SSHError)?.userMessage ?? error.localizedDescription
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
