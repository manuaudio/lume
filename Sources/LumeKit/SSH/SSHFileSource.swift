import Foundation

/// `FileSource` over an SSH host. Every operation is an sftp batch through the
/// host's `SSHTransport`; output parsing lives in `SFTPListingParser`.
public actor SSHFileSource: FileSource {
    public nonisolated let id: SourceID
    let transport: SSHTransport
    private let tempDir: URL
    /// Injectable so atomic-write tests get deterministic temp names.
    private let tempSuffix: @Sendable () -> String

    public init(host: SSHHost, transport: SSHTransport,
                tempDir: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumeSSH", isDirectory: true),
                tempSuffix: @escaping @Sendable () -> String = { UUID().uuidString.prefix(8).lowercased() }) {
        self.id = .ssh(alias: host.alias)
        self.transport = transport
        self.tempDir = tempDir
        self.tempSuffix = tempSuffix
    }

    /// Double-quote a path for an sftp batch command (handles spaces; escapes
    /// embedded quotes/backslashes).
    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"\(escaped)\""
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let out = try await transport.sftp(["ls -la \(Self.quote(path))"], path: path)
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        return SFTPListingParser.parse(out)
            .filter { TreeFilterRules.isVisible(name: $0.name, includeHidden: includeHidden) }
            .map { entry in
                ResourceNode(
                    ref: ResourceRef(sourceID: id, path: "\(base)/\(entry.name)"),
                    isDirectory: entry.isDirectory,
                    isSymlink: entry.isSymlink
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }  // folders first
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    public func read(_ path: String) async throws -> String {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let local = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        _ = try await transport.sftp(
            ["get \(Self.quote(path)) \(Self.quote(local.path))"], path: path)
        guard let data = try? Data(contentsOf: local) else {
            throw SSHError.protocolFailure(detail: "download of \(path) produced no file")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SSHError.protocolFailure(detail: "\(path) isn't UTF-8 text")
        }
        return text
    }

    /// File-oriented stat: `ls -la <file>` lists exactly that file. If sftp
    /// listed multiple entries instead, `path` was a directory.
    public func stat(_ path: String) async throws -> ResourceMeta {
        let out = try await transport.sftp(["ls -la \(Self.quote(path))"], path: path)
        let entries = SFTPListingParser.parse(out)
        let name = (path as NSString).lastPathComponent
        if entries.count == 1, let entry = entries.first,
           entry.name == name || entry.name == path || entry.name.hasSuffix("/\(name)") {
            return ResourceMeta(isDirectory: entry.isDirectory, size: entry.size, mode: entry.mode)
        }
        // Contents got listed (or empty dir): it's a directory.
        return ResourceMeta(isDirectory: true, size: nil, mode: nil)
    }

    /// Resolve a (possibly relative) remote path — used to turn the initial
    /// "." into the absolute home directory for breadcrumbs/recents.
    public func realpath(_ path: String) async throws -> String {
        let out = try await transport.sftp(["cd \(Self.quote(path))", "pwd"], path: path)
        guard let resolved = SFTPListingParser.workingDirectory(in: out) else {
            throw SSHError.protocolFailure(detail: "couldn't resolve remote path \(path)")
        }
        return resolved
    }

    public func write(_ text: String, to path: String) async throws {
        // Implemented in the next task (atomic temp + rename).
        throw SSHError.protocolFailure(detail: "write not implemented yet")
    }
}
