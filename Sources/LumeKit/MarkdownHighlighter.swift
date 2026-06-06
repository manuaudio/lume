import Foundation

public enum HighlightKind: Equatable, Sendable {
    case heading
    case strong
    case emphasis
    case code
    case link
}

/// A styled range within a markdown string. Ranges are `NSRange` (UTF-16) so
/// they apply directly to an `NSTextStorage` without conversion.
public struct HighlightToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: HighlightKind

    public init(range: NSRange, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// Pure markdown tokenizer. Lightweight by design — covers the inline/block
/// constructs a writer sees constantly, not the full CommonMark grammar.
public enum MarkdownHighlighter {
    private struct Rule {
        let kind: HighlightKind
        let regex: NSRegularExpression
    }

    private static let rules: [Rule] = {
        func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Patterns here are compile-time constants; force-try is safe.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            Rule(kind: .heading, regex: re("^#{1,6}[ \\t].*$", [.anchorsMatchLines])),
            Rule(kind: .strong, regex: re("\\*\\*[^*\\n]+\\*\\*")),
            Rule(kind: .emphasis, regex: re("(?<![\\w*])[*_][^*_\\n]+[*_](?![\\w*])")),
            Rule(kind: .code, regex: re("`[^`\\n]+`")),
            Rule(kind: .link, regex: re("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)")),
        ]
    }()

    public static func tokens(in text: String) -> [HighlightToken] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var tokens: [HighlightToken] = []
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                tokens.append(HighlightToken(range: match.range, kind: rule.kind))
            }
        }
        return tokens
    }
}
