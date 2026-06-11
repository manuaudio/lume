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
    ///
    /// Throws `SSHError.protocolFailure` if `path` contains a newline or
    /// carriage-return character: sftp's batch tokenizer splits on newlines
    /// unconditionally and no escape sequence exists, so the command would be
    /// silently truncated or corrupted.
    static func quote(_ path: String) throws -> String {
        guard !path.contains("\n"), !path.contains("\r") else {
            throw SSHError.protocolFailure(detail: "filename contains a newline: \(path)")
        }
        let escaped = path
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"\(escaped)\""
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let out = try await transport.sftp(["ls -la \(try Self.quote(path))"], path: path)
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
        // Process-private downloads dir; 0700 so another local user can't pre-plant a symlink.
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        let local = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        _ = try await transport.sftp(
            ["get \(try Self.quote(path)) \(try Self.quote(local.path))"], path: path)
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
    ///
    /// Known limitation: a directory whose single child shares the directory's
    /// own name (e.g. /srv/app/app as only entry of /srv/app) is misreported as
    /// a file; callers treat stat results as hints, and the subsequent sftp
    /// operation surfaces the real error.
    public func stat(_ path: String) async throws -> ResourceMeta {
        let out = try await transport.sftp(["ls -la \(try Self.quote(path))"], path: path)
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
        let out = try await transport.sftp(["cd \(try Self.quote(path))", "pwd"], path: path)
        guard let resolved = SFTPListingParser.workingDirectory(in: out) else {
            throw SSHError.protocolFailure(detail: "couldn't resolve remote path \(path)")
        }
        return resolved
    }

    /// Atomic, permission-preserving save:
    ///   1. stat the original (mode capture — also fails fast if it vanished),
    ///   2. upload the buffer to `<path>.lume-tmp-<suffix>` in the same dir,
    ///   3. chmod the temp to the original's mode,
    ///   4. rename over the original (OpenSSH uses posix-rename → atomic).
    ///
    /// The original is never touched until the rename, so readers can never
    /// observe a partial file — even if the rename itself fails the original
    /// is intact. On any batch failure the temp is removed best-effort; if
    /// that cleanup sftp call also fails the remote temp is an orphan, but the
    /// original is still unmodified and the caller's data is safe.
    public func write(_ text: String, to path: String) async throws {
        let meta = try await stat(path)
        let mode = String(format: "%o", (meta.mode ?? 0o644) & 0o777)
        let remoteTemp = "\(path).lume-tmp-\(tempSuffix())"

        // Process-private staging dir; 0700 so another local user can't
        // pre-plant a symlink (mirrors the same guard in read()).
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        let local = tempDir.appendingPathComponent(UUID().uuidString)
        // Register cleanup BEFORE the write so a failed/partial local write
        // can't leave a stale staging file behind.
        defer { try? FileManager.default.removeItem(at: local) }
        try Data(text.utf8).write(to: local)

        // Hoist quoted strings into lets — `try` inside string interpolations
        // or array literals is not allowed in Swift 6.
        let quotedLocal      = try Self.quote(local.path)
        let quotedRemoteTemp = try Self.quote(remoteTemp)
        let quotedPath       = try Self.quote(path)

        do {
            _ = try await transport.sftp([
                "put \(quotedLocal) \(quotedRemoteTemp)",
                "chmod \(mode) \(quotedRemoteTemp)",
                "rename \(quotedRemoteTemp) \(quotedPath)",
            ], path: path)
        } catch {
            // Best-effort cleanup of the remote temp. sftp's `-b` flag aborts
            // the batch at the first failing command, so the rename (step 4)
            // was never reached and the original is untouched.
            _ = try? await transport.sftp(["rm \(quotedRemoteTemp)"])
            throw error
        }
    }
}
