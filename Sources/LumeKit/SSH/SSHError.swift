import Foundation

/// Typed failures from the SSH layer, each with a human message. `map`
/// classifies raw ssh/sftp stderr (the only error channel a subprocess gives us).
public enum SSHError: Error, Equatable, Sendable {
    case connectFailed(detail: String)
    case authFailed
    case timeout(executable: String)
    case permissionDenied(path: String)
    case notFound(path: String)
    case connectionLost
    case protocolFailure(detail: String)

    public var userMessage: String {
        switch self {
        case .connectFailed(let detail):
            return "Couldn't connect: \(detail)"
        case .authFailed:
            return "Authentication failed. Check your SSH keys (or add the key to ssh-agent) and try again."
        case .timeout(let executable):
            return "The remote operation timed out (\((executable as NSString).lastPathComponent))."
        case .permissionDenied(let path):
            return "The remote user can't write \(path)."
        case .notFound(let path):
            return "\(path) doesn't exist on the remote."
        case .connectionLost:
            return "Connection lost."
        case .protocolFailure(let detail):
            return "SSH error: \(detail)"
        }
    }

    /// Classify a failed ssh/sftp invocation by its stderr. Order matters:
    /// ssh's auth failure ("Permission denied (publickey…)") must win over the
    /// generic file-level "Permission denied".
    public static func map(exitCode: Int32, stderr: Data, path: String?) -> SSHError {
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission denied (") { return .authFailed }
        if lower.contains("permission denied") { return .permissionDenied(path: path ?? "the file") }
        if lower.contains("no such file") { return .notFound(path: path ?? "the path") }
        if lower.contains("connection refused") || lower.contains("could not resolve")
            || lower.contains("operation timed out") || lower.contains("network is unreachable") {
            return .connectFailed(detail: text)
        }
        if lower.contains("connection closed") || lower.contains("broken pipe")
            || lower.contains("mux_client") || lower.contains("connection reset") {
            return .connectionLost
        }
        return .protocolFailure(detail: text.isEmpty ? "exit code \(exitCode)" : text)
    }
}
