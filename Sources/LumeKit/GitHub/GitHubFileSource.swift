import Foundation

/// `FileSource` over one GitHub repository + active branch. Every operation is
/// a `GitHubClient` call; reads capture each file's blob sha in actor state and
/// writes send it back — GitHub then rejects the PUT if the file changed
/// remotely (the conflict the UI surfaces as "reload or keep editing").
public actor GitHubFileSource: FileSource {
    public nonisolated let id: SourceID
    private let slug: String
    private let client: GitHubClient
    private var branch: String?
    /// Blob sha by ResourceRef-style path ("/docs/a.md"), captured at read time.
    private var shaByPath: [String: String] = [:]

    public init(slug: String, client: GitHubClient) {
        self.id = .github(slug: slug)
        self.slug = slug
        self.client = client
    }

    /// Switch the active branch. Cached shas belong to the old branch's blobs,
    /// so they're dropped — files must be re-read before they can be saved.
    public func setBranch(_ name: String) {
        branch = name
        shaByPath.removeAll()
    }

    /// "/docs/a.md" → "docs/a.md" (the contents API takes repo-relative paths).
    static func apiPath(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let entries = try await client.listDirectory(slug: slug, path: Self.apiPath(path), ref: branch)
        let base = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        return entries
            .filter { $0.type != "submodule" }   // not browsable content (MVP)
            .filter { TreeFilterRules.isVisible(name: $0.name, includeHidden: includeHidden) }
            .map { entry in
                ResourceNode(
                    ref: ResourceRef(sourceID: id, path: "\(base)/\(entry.name)"),
                    isDirectory: entry.type == "dir",
                    isSymlink: entry.type == "symlink"
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }  // folders first
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    public func read(_ path: String) async throws -> String {
        let file = try await client.readFile(slug: slug, path: Self.apiPath(path), ref: branch)
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw GitHubError.notUTF8(path: path)
        }
        shaByPath[path] = file.sha
        return text
    }

    public func write(_ text: String, to path: String) async throws {
        guard let branch else {
            throw GitHubError.protocolFailure(detail: "no active branch")
        }
        guard let sha = shaByPath[path] else {
            // Programmer-error guard: the editor always reads before saving.
            throw GitHubError.protocolFailure(detail: "write before read: \(path)")
        }
        let repoPath = Self.apiPath(path)
        let newSha = try await client.writeFile(
            slug: slug, path: repoPath, content: Data(text.utf8),
            message: "Update \(repoPath)", sha: sha, branch: branch)
        shaByPath[path] = newSha   // consecutive saves keep working
    }

    public func stat(_ path: String) async throws -> ResourceMeta {
        try await client.stat(slug: slug, path: Self.apiPath(path), ref: branch)
    }
}
