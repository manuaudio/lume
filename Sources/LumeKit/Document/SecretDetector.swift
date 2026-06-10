import Foundation

/// Flags filenames — and, for bulk copies, file CONTENTS — that likely contain
/// secrets, so the UI can warn before they are copied into a chatbot paste.
public enum SecretDetector {

    // MARK: - Filename heuristics

    public static func sensitiveFiles(in urls: [URL]) -> [URL] {
        urls.filter { isSensitive($0.lastPathComponent) }
    }

    public static func isSensitive(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        if exactNames.contains(lower) { return true }
        if keyMaterialExtensions.contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ecdsa")
            || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_dsa") { return true }
        if lower.hasPrefix("service-account"), lower.hasSuffix(".json") { return true }
        if containsWord("secret", in: lower) || containsWord("credential", in: lower) { return true }
        return false
    }

    /// Dotfiles that are credential stores by convention.
    private static let exactNames: Set<String> = [
        ".netrc", ".npmrc", ".pgpass", ".git-credentials",
    ]

    /// Key-material extensions: flagged regardless of base name.
    private static let keyMaterialExtensions: [String] = [
        ".pem", ".key", ".p8", ".p12", ".pfx", ".jks", ".keystore", ".ppk",
    ]

    /// True when `word` occurs in `lower` NOT as a prefix of a longer word —
    /// "client_secret.json" and "aws_credentials" match, "secretary.md"
    /// doesn't. An optional plural "s" is allowed.
    private static func containsWord(_ word: String, in lower: String) -> Bool {
        var search = lower[...]
        while let range = search.range(of: word) {
            var end = range.upperBound
            if end < lower.endIndex, lower[end] == "s" { end = lower.index(after: end) }
            if end == lower.endIndex || !lower[end].isLetter { return true }
            search = lower[range.upperBound...]
        }
        return false
    }

    // MARK: - Content heuristics

    /// Why a piece of content was flagged; `label` drives the warning copy.
    public enum ContentMatch: String, CaseIterable, Sendable {
        case awsAccessKeyID = "an AWS access key ID"
        case privateKeyBlock = "a private key block"
        case gitHubToken = "a GitHub token"
        case slackToken = "a Slack token"
        case skAPIKey = "an sk-… API key"
        case highEntropyAssignment = "a long credential-looking assignment"

        public var label: String { rawValue }
    }

    /// True when `content` contains something shaped like a credential.
    public static func containsLikelySecret(_ content: String) -> Bool {
        firstContentMatch(in: content) != nil
    }

    /// The first content pattern that matches, or nil. Every pattern is a
    /// fixed token shape with single, non-nested quantifiers over disjoint
    /// adjacent character classes — linear-time on adversarial input (no ReDoS).
    public static func firstContentMatch(in content: String) -> ContentMatch? {
        let range = NSRange(content.startIndex..., in: content)
        for (kind, regex) in contentRules
            where regex.firstMatch(in: content, options: [], range: range) != nil {
            return kind
        }
        return nil
    }

    private static let contentRules: [(ContentMatch, NSRegularExpression)] = {
        func re(_ pattern: String,
                _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Patterns are compile-time constants; a typo is a programmer error.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            (.awsAccessKeyID, re("AKIA[0-9A-Z]{16}")),
            (.privateKeyBlock, re("-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----")),
            (.gitHubToken, re("\\bgh[pousr]_[A-Za-z0-9]{20,}")),
            (.slackToken, re("\\bxox[baprs]-[A-Za-z0-9-]{10,}")),
            (.skAPIKey, re("\\bsk-[A-Za-z0-9_-]{24,}")),
            // key/secret/token/password = (or :) a 32+ char base64/hex-ish
            // value. Long enough that prose and ordinary code don't trip it.
            (.highEntropyAssignment,
             re("(?:key|secret|token|password|passwd|pwd)[\"']?[ \\t]{0,8}[:=][ \\t]{0,8}[\"']?[A-Za-z0-9+/=]{32,}",
                [.caseInsensitive])),
        ]
    }()
}
