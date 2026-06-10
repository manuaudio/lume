import Foundation

/// One `KEY=VALUE` pair from a `.env` file.
public struct EnvEntry: Equatable, Sendable {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A parsed line of a `.env` file.
public enum EnvLine: Equatable, Sendable {
    case entry(EnvEntry)
    case comment(String)
    case blank
}

public enum EnvFile {
    private static let maxMaskDots = 24

    /// Parse `.env` text into ordered lines, preserving comments and blanks.
    /// Splits on any newline grapheme (`\n`, `\r\n`, `\r`) so CRLF files don't
    /// leak a trailing `\r` into values or defeat quote-stripping.
    public static func parse(_ text: String) -> [EnvLine] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { rawSub in
            let raw = String(rawSub)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .blank }
            if trimmed.hasPrefix("#") { return .comment(raw) }
            guard let eq = raw.firstIndex(of: "=") else { return .comment(raw) }
            var key = String(raw[raw.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") {
                key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            let value = stripSurroundingQuotes(
                String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            )
            return .entry(EnvEntry(key: key, value: value))
        }
    }

    /// Extract just the entries (drop comments/blanks).
    public static func entries(from lines: [EnvLine]) -> [EnvEntry] {
        lines.compactMap { if case let .entry(e) = $0 { return e } else { return nil } }
    }

    /// Strip one layer of matching surrounding quotes (`"` or `'`). Real `.env`
    /// files mix quoted and unquoted values; both should display the same.
    static func stripSurroundingQuotes(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last,
              first == last, first == "\"" || first == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Mask a secret value as bullet dots, capped at 24.
    public static func mask(_ value: String) -> String {
        String(repeating: "•", count: min(value.count, maxMaskDots))
    }
}
