import Foundation
import Observation
import os

/// Everything Lume remembers about SSH connections: manually-entered hosts
/// plus per-host last path / recent files. JSON in Application Support —
/// deliberately NOT the SwiftData library store (no relationships needed, and
/// the library schema has delicate migration constraints).
public struct ConnectionStoreState: Codable, Sendable, Equatable {
    public var manualHosts: [SSHHost] = []
    public var hostState: [String: HostState] = [:]   // keyed by alias

    public init() {}

    public struct HostState: Codable, Sendable, Equatable {
        public var lastPath: String?
        public var recentFiles: [String] = []
        public var lastUsed: Date?
        public init() {}
    }
}

@MainActor
@Observable
public final class ConnectionStore {
    public private(set) var state: ConnectionStoreState
    private let fileURL: URL
    private static let recentsCap = 8

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume/connections.json")
    }

    public init(fileURL: URL = ConnectionStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = (try? decoder.decode(ConnectionStoreState.self, from: data)) ?? ConnectionStoreState()
        } else {
            state = ConnectionStoreState()
        }
    }

    public func addManualHost(_ host: SSHHost) {
        state.manualHosts.removeAll { $0.alias == host.alias }
        state.manualHosts.append(host)
        persist()
    }

    public func removeManualHost(alias: String) {
        state.manualHosts.removeAll { $0.alias == alias }
        state.hostState[alias] = nil
        persist()
    }

    public func noteConnected(alias: String) {
        state.hostState[alias, default: .init()].lastUsed = Date()
        persist()
    }

    public func noteBrowsed(alias: String, path: String) {
        state.hostState[alias, default: .init()].lastPath = path
        persist()
    }

    public func noteOpened(alias: String, file: String) {
        var hostState = state.hostState[alias, default: .init()]
        hostState.recentFiles.removeAll { $0 == file }
        hostState.recentFiles.insert(file, at: 0)
        if hostState.recentFiles.count > Self.recentsCap {
            hostState.recentFiles.removeLast(hostState.recentFiles.count - Self.recentsCap)
        }
        state.hostState[alias] = hostState
        persist()
    }

    /// Best-effort persistence: a failed save loses only connection metadata
    /// (recents/last paths), so failures are logged rather than surfaced.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("connections.json save failed: \(error.localizedDescription)")
        }
    }

    private static let logger = Logger(subsystem: "com.lume.Lume", category: "ConnectionStore")
}
