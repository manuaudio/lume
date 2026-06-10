import Foundation

/// Extracts connectable host nicknames from ssh_config text. Lume only needs
/// the aliases for its pick list — ssh itself resolves user/port/keys when we
/// shell out, so everything else in the file is deliberately ignored.
public enum SSHConfigParser {
    /// Concrete `Host` aliases, in file order. Wildcard (`*`, `?`) and negated
    /// (`!`) patterns are option-scoping, not connectable names — skipped.
    public static func aliases(in text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Match blocks are implicitly ignored — they never start with "Host ".
            guard line.count > 5,
                  line.prefix(4).lowercased() == "host",
                  line[line.index(line.startIndex, offsetBy: 4)] == " "
                    || line[line.index(line.startIndex, offsetBy: 4)] == "\t"
                    || line[line.index(line.startIndex, offsetBy: 4)] == "="
            else { continue }
            let rest = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "= \t"))
            let patterns = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
            for pattern in patterns {
                let alias = String(pattern)
                if alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") { continue }
                if seen.insert(alias).inserted { result.append(alias) }
            }
        }
        return result
    }

    /// Like `aliases(in:)` but follows `Include` directives one level deep via
    /// an injectable reader (the app passes a file reader; tests pass a stub).
    /// Glob patterns in Include paths are passed to the reader verbatim.
    public static func aliases(configText: String,
                               reader: (String) -> String?) -> [String] {
        var combined = configText
        for raw in configText.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Require "include" (7 chars) followed immediately by a space, tab, or =
            // so that e.g. "IncludeX foo" is NOT treated as an Include directive.
            guard line.count > 8,
                  line.prefix(7).lowercased() == "include",
                  line[line.index(line.startIndex, offsetBy: 7)] == " "
                    || line[line.index(line.startIndex, offsetBy: 7)] == "\t"
                    || line[line.index(line.startIndex, offsetBy: 7)] == "="
            else { continue }
            let path = String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "= \t"))
            if !path.isEmpty, let included = reader(path) {
                combined += "\n" + included
            }
        }
        return aliases(in: combined)
    }
}
