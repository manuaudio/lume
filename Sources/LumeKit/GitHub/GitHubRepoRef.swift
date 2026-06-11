import Foundation

/// One GitHub repository, parsed from user input: a bare "owner/repo" slug,
/// a github.com URL (https or ssh, .git suffix, tree/blob deep links), all
/// reduce to the same owner/name pair.
///
/// Validation is deliberately lenient (one shared charset for owner and
/// repo): a name GitHub wouldn't accept simply 404s at the API.
public struct GitHubRepoRef: Hashable, Sendable {
    public let owner: String
    public let name: String

    public var slug: String { "\(owner)/\(name)" }

    public init?(parsing raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let range = s.range(of: "github.com", options: .caseInsensitive) {
            // range(of:) is a substring search — guard the host boundary so
            // e.g. "github.community" or "mygithub.com" can't masquerade.
            let after = range.upperBound < s.endIndex ? s[range.upperBound] : "/"
            let before = range.lowerBound > s.startIndex
                ? s[s.index(before: range.lowerBound)] : "/"
            guard after == ":" || after == "/",
                  !before.isLetter, !before.isNumber else { return nil }
            // URL form: everything after the host, ":" (ssh) or "/" (https).
            s = String(s[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
            let parts = s.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }   // deep links: keep first two
            owner = parts[0]
            name = Self.stripGitSuffix(parts[1])
        } else {
            let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            owner = parts[0]
            name = Self.stripGitSuffix(parts[1])
        }
        guard Self.isValidSegment(owner), Self.isValidSegment(name) else { return nil }
    }

    private static func stripGitSuffix(_ s: String) -> String {
        s.hasSuffix(".git") ? String(s.dropLast(4)) : s
    }

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")

    private static func isValidSegment(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
