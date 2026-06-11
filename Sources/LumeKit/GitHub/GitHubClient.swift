import Foundation

/// Repo metadata: default branch + whether the signed-in user can push.
public struct GitHubRepoInfo: Equatable, Sendable {
    public let defaultBranch: String
    public let canPush: Bool

    public init(defaultBranch: String, canPush: Bool) {
        self.defaultBranch = defaultBranch
        self.canPush = canPush
    }
}

/// One entry of a contents-API directory listing.
public struct GitHubDirEntry: Equatable, Sendable {
    public let name: String
    public let type: String     // "file" | "dir" | "symlink" | "submodule"
    public let size: Int64
    public let sha: String

    public init(name: String, type: String, size: Int64, sha: String) {
        self.name = name
        self.type = type
        self.size = size
        self.sha = sha
    }
}

/// A downloaded file: raw bytes + the blob sha captured at read time
/// (the optimistic-concurrency token for the next write).
public struct GitHubRemoteFile: Equatable, Sendable {
    public let data: Data
    public let sha: String

    public init(data: Data, sha: String) {
        self.data = data
        self.sha = sha
    }
}

/// One row of the "your repos" picker.
public struct GitHubRepoSummary: Equatable, Sendable, Identifiable {
    public let slug: String
    public let isPrivate: Bool

    public var id: String { slug }

    public init(slug: String, isPrivate: Bool) {
        self.slug = slug
        self.isPrivate = isPrivate
    }
}

/// Thin wrapper over the `gh` CLI: every operation is one subprocess through
/// `CommandRunning` (the same seam as ssh/sftp), so all logic above it is
/// unit-testable with `FakeCommandRunner`. Auth is gh's own (`gh auth login`)
/// — Lume never sees or stores a token.
public struct GitHubClient: Sendable {
    private let runner: CommandRunning
    private let ghPath: String?

    public init(runner: CommandRunning = ProcessRunner(), ghPath: String? = GitHubClient.locateGh()) {
        self.runner = runner
        self.ghPath = ghPath
    }

    /// Standard install locations first, then $PATH.
    public static func locateGh() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Non-interactive, no-noise environment for every gh call.
    private static let environment = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1",
    ]

    /// Throws `.notAuthenticated` unless `gh auth status` succeeds.
    public func checkAuth() async throws {
        guard let ghPath else { throw GitHubError.ghNotInstalled }
        let result = try await runner.run(ghPath, ["auth", "status"], stdin: nil,
                                          environment: Self.environment, timeout: 15)
        guard result.exitCode == 0 else { throw GitHubError.notAuthenticated }
    }

    public func repoInfo(slug: String) async throws -> GitHubRepoInfo {
        struct Raw: Decodable {
            let defaultBranch: String
            let permissions: Permissions?
            struct Permissions: Decodable { let push: Bool }
            enum CodingKeys: String, CodingKey {
                case defaultBranch = "default_branch", permissions
            }
        }
        let raw = try Self.decode(Raw.self, from: try await api("repos/\(slug)"))
        return GitHubRepoInfo(defaultBranch: raw.defaultBranch,
                              canPush: raw.permissions?.push ?? false)
    }

    public func listDirectory(slug: String, path: String, ref: String?) async throws -> [GitHubDirEntry] {
        struct Raw: Decodable { let name: String; let type: String; let size: Int64; let sha: String }
        let data = try await api(Self.contentsEndpoint(slug: slug, path: path, ref: ref),
                                 path: path.isEmpty ? "/" : path)
        do {
            return try JSONDecoder().decode([Raw].self, from: data)
                .map { GitHubDirEntry(name: $0.name, type: $0.type, size: $0.size, sha: $0.sha) }
        } catch {
            throw GitHubError.protocolFailure(detail: "\(path.isEmpty ? "/" : path) is not a directory")
        }
    }

    public func readFile(slug: String, path: String, ref: String?) async throws -> GitHubRemoteFile {
        struct Raw: Decodable { let content: String?; let encoding: String?; let sha: String }
        let raw = try Self.decode(Raw.self, from: try await api(
            Self.contentsEndpoint(slug: slug, path: path, ref: ref), path: path))
        if raw.encoding == "base64", let content = raw.content, !content.isEmpty,
           let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }) {
            return GitHubRemoteFile(data: decoded, sha: raw.sha)
        }
        // Contents API truncates files >1 MB (encoding "none"): re-fetch the blob by sha.
        struct Blob: Decodable { let content: String }
        let blob = try Self.decode(Blob.self,
                                   from: try await api("repos/\(slug)/git/blobs/\(raw.sha)", path: path))
        guard let decoded = Data(base64Encoded: blob.content.filter { !$0.isWhitespace }) else {
            throw GitHubError.protocolFailure(detail: "undecodable blob for \(path)")
        }
        return GitHubRemoteFile(data: decoded, sha: raw.sha)
    }

    /// PUT the contents API with the read-time sha; returns the new blob sha.
    public func writeFile(slug: String, path: String, content: Data, message: String,
                          sha: String, branch: String) async throws -> String {
        struct Body: Encodable { let message: String; let content: String; let branch: String; let sha: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // deterministic for tests
        let body = try encoder.encode(Body(message: message,
                                           content: content.base64EncodedString(),
                                           branch: branch, sha: sha))
        struct Resp: Decodable {
            let content: C
            struct C: Decodable { let sha: String }
        }
        let data = try await api("repos/\(slug)/contents/\(Self.encodePath(path))",
                                 method: "PUT", body: body, path: path)
        return try Self.decode(Resp.self, from: data).content.sha
    }

    public func listBranches(slug: String) async throws -> [String] {
        // One page of 100 covers typical repos — deliberate MVP cap (no --paginate).
        struct Raw: Decodable { let name: String }
        let data = try await api("repos/\(slug)/branches?per_page=100")
        return try Self.decode([Raw].self, from: data).map(\.name)
    }

    public func listUserRepos() async throws -> [GitHubRepoSummary] {
        guard let ghPath else { throw GitHubError.ghNotInstalled }
        // Deliberate MVP cap at 200; arbitrary repos remain reachable via manual entry.
        let result = try await runner.run(
            ghPath, ["repo", "list", "--limit", "200", "--json", "nameWithOwner,isPrivate"],
            stdin: nil, environment: Self.environment, timeout: 30)
        guard result.exitCode == 0 else {
            throw GitHubError.map(exitCode: result.exitCode, stdout: result.stdout,
                                  stderr: result.stderr, path: nil)
        }
        struct Raw: Decodable { let nameWithOwner: String; let isPrivate: Bool }
        return try Self.decode([Raw].self, from: result.stdout)
            .map { GitHubRepoSummary(slug: $0.nameWithOwner, isPrivate: $0.isPrivate) }
    }

    /// Directory vs file: the contents API returns a JSON array for
    /// directories and an object for files.
    public func stat(slug: String, path: String, ref: String?) async throws -> ResourceMeta {
        let data = try await api(Self.contentsEndpoint(slug: slug, path: path, ref: ref), path: path)
        let firstByte = data.first { !Set("\t\n\r ".utf8).contains($0) }
        if firstByte == UInt8(ascii: "[") { return ResourceMeta(isDirectory: true) }
        struct Raw: Decodable { let size: Int64? }
        let raw = try Self.decode(Raw.self, from: data)
        return ResourceMeta(isDirectory: false, size: raw.size)
    }

    // MARK: - Internals

    private func api(_ endpoint: String, method: String? = nil, body: Data? = nil,
                     path: String? = nil, timeout: TimeInterval = 30) async throws -> Data {
        guard let ghPath else { throw GitHubError.ghNotInstalled }
        var args = ["api", endpoint]
        if let method { args += ["--method", method] }
        if body != nil { args += ["--input", "-"] }
        let result = try await runner.run(ghPath, args, stdin: body,
                                          environment: Self.environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GitHubError.map(exitCode: result.exitCode, stdout: result.stdout,
                                  stderr: result.stderr, path: path)
        }
        return result.stdout
    }

    static func contentsEndpoint(slug: String, path: String, ref: String?) -> String {
        var endpoint = "repos/\(slug)/contents"
        if !path.isEmpty { endpoint += "/\(encodePath(path))" }
        if let ref { endpoint += "?ref=\(encodeRef(ref))" }
        return endpoint
    }

    /// Percent-encode each path segment (spaces, '#', '?', '%'), keeping "/".
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    /// Branch names: keep "/" (feature/x) — it's legal inside a query value.
    private static let refAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

    static func encodeRef(_ ref: String) -> String {
        ref.addingPercentEncoding(withAllowedCharacters: refAllowed) ?? ref
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GitHubError.protocolFailure(detail: "unexpected GitHub response") }
    }
}
