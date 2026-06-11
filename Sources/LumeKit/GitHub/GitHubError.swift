import Foundation

/// Typed failures from the GitHub layer, each with a human message. `map`
/// classifies a failed `gh` invocation by its exit code, stderr, and (when
/// present) the JSON error body on stdout.
public enum GitHubError: Error, Equatable, Sendable {
    case ghNotInstalled
    case notAuthenticated
    case repoNotFound
    case branchNotFound
    case notFound(path: String)
    case writeConflict(path: String)
    case permissionDenied
    case rateLimited
    case notUTF8(path: String)
    case network(detail: String)
    case protocolFailure(detail: String)

    public var userMessage: String {
        switch self {
        case .ghNotInstalled:
            return "GitHub CLI not found. Install it with `brew install gh`, then try again."
        case .notAuthenticated:
            return "Not signed in to GitHub. Run `gh auth login` in Terminal, then retry."
        case .repoNotFound:
            return "Repository not found — check the name, or sign in with an account that can see it."
        case .branchNotFound:
            return "That branch no longer exists on GitHub."
        case .notFound(let path):
            return "\(path) doesn't exist in this repository."
        case .writeConflict(let path):
            return "\((path as NSString).lastPathComponent) changed on GitHub since you opened it."
        case .permissionDenied:
            return "You don't have push access to this repository."
        case .rateLimited:
            return "GitHub rate limit reached. Try again in a few minutes."
        case .notUTF8(let path):
            return "\((path as NSString).lastPathComponent) isn't UTF-8 text."
        case .network(let detail):
            return "Network error: \(detail)"
        case .protocolFailure(let detail):
            return "GitHub error: \(detail)"
        }
    }

    /// Classify a failed gh invocation. Order matters: rate-limit responses
    /// are HTTP 403 and must win over the generic permission-denied 403;
    /// "No commit found for the ref" is a 404 and must win over repo/file 404.
    public static func map(exitCode: Int32, stdout: Data, stderr: Data, path: String?) -> GitHubError {
        let err = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (err + "\n" + String(decoding: stdout, as: UTF8.self)).lowercased()
        if combined.contains("rate limit") { return .rateLimited }
        if combined.contains("gh auth login") || combined.contains("not logged in") {
            return .notAuthenticated
        }
        if combined.contains("no commit found for the ref") { return .branchNotFound }
        if combined.contains("http 409") { return .writeConflict(path: path ?? "the file") }
        if combined.contains("http 422"), combined.contains("sha") {
            return .writeConflict(path: path ?? "the file")
        }
        if combined.contains("http 403") { return .permissionDenied }
        if combined.contains("http 404") {
            if let path { return .notFound(path: path) }
            return .repoNotFound
        }
        if combined.contains("no such host") || combined.contains("dial tcp")
            || combined.contains("connection refused") || combined.contains("timeout")
            || combined.contains("network is unreachable") || combined.contains("could not resolve") {
            return .network(detail: err)
        }
        return .protocolFailure(detail: err.isEmpty ? "exit code \(exitCode)" : err)
    }
}
