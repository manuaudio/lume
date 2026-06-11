import Foundation
import LumeKit

/// SSH backend lifecycle: ControlMaster connect + start-path resolution.
/// Owns the transport and source; `RemoteSession` only sees the protocols.
@MainActor
final class SSHConnection: RemoteConnection {
    let host: SSHHost
    let transport: SSHTransport
    let source: SSHFileSource
    private let startPath: String?

    init(host: SSHHost, startPath: String?) {
        self.host = host
        self.startPath = startPath
        let transport = SSHTransport(host: host)
        self.transport = transport
        self.source = SSHFileSource(host: host, transport: transport)
    }

    var sourceID: SourceID { .ssh(alias: host.alias) }
    var displayName: String { host.alias }

    func connect() async throws -> String {
        try await transport.connect()
        let start = startPath ?? "."
        return start.hasPrefix("/") ? start : try await source.realpath(start)  // "." → home dir
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func userMessage(for error: Error) -> String {
        (error as? SSHError)?.userMessage ?? error.localizedDescription
    }
}
