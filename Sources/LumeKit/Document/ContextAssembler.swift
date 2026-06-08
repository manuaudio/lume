import Foundation

/// The result of bundling files' contents for an LLM paste.
public struct AssembledContext: Equatable, Sendable {
    public let text: String
    /// Estimated tokens for the FULL assembled text, including wrapper tags/fences (ceil of chars÷4).
    public let tokenEstimate: Int
    public let fileCount: Int
    public let unreadable: [URL]
}

/// Reads files and wraps their contents into one pasteable blob.
/// Pure and `nonisolated` — safe to run off the main actor and unit-test directly.
public enum ContextAssembler {

    public static func assemble(_ urls: [URL], format: ContextFormat) -> AssembledContext {
        var pieces: [(url: URL, body: String)] = []
        var unreadable: [URL] = []
        for url in urls {
            // Skip absurdly large files (valid UTF-8 logs/DBs) to avoid a memory spike.
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if let size, size > 10 * 1024 * 1024 {
                unreadable.append(url)
                continue
            }
            if let body = try? String(contentsOf: url, encoding: .utf8) {
                pieces.append((url, body))
            } else {
                unreadable.append(url)
            }
        }
        guard !pieces.isEmpty else {
            return AssembledContext(text: "", tokenEstimate: 0, fileCount: 0, unreadable: unreadable)
        }

        let text: String
        switch format {
        case .xml:
            let docs = pieces.map { p in
                "<document path=\"\(xmlAttrEscape(displayPath(p.url)))\">\n\(xmlBodyEscape(p.body))\n</document>"
            }.joined(separator: "\n")
            text = "<documents>\n\(docs)\n</documents>"
        case .markdown:
            text = pieces.map { p in
                let lang = fenceLanguage(for: p.url)
                let fence = fence(for: p.body)
                return "## \(displayPath(p.url))\n\(fence)\(lang)\n\(p.body)\n\(fence)"
            }.joined(separator: "\n\n")
        }

        let estimate = TokenEstimator.estimate(text)
        return AssembledContext(text: text, tokenEstimate: estimate,
                                fileCount: pieces.count, unreadable: unreadable)
    }

    /// Absolute POSIX path with the home directory shown as `~`.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Markdown code-fence language inferred from the filename.
    static func fenceLanguage(for url: URL) -> String {
        let name = url.lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") { return "bash" }
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "markdown"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "py": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "jsx": return "typescript"
        case "sh", "bash", "zsh": return "bash"
        case "swift": return "swift"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "xml": return "xml"
        case "html", "htm": return "html"
        case "css", "scss": return "css"
        default: return ""
        }
    }

    /// A backtick fence guaranteed longer than the longest backtick run in `body`
    /// (so a file that itself contains ``` blocks can't break out). Minimum 3.
    static func fence(for body: String) -> String {
        var longest = 0, current = 0
        for ch in body {
            if ch == "`" { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func xmlAttrEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
    }

    static func xmlBodyEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
