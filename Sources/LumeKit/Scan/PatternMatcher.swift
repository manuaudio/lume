import Foundation

/// Matches a filename against a pattern. Supports exact names and `*` globs,
/// case-insensitively. `*` matches any (possibly empty) run of characters.
public enum PatternMatcher {

    public static func matchesAny(filename: String, patterns: [String]) -> Bool {
        patterns.contains { matches(filename: filename, pattern: $0) }
    }

    public static func matches(filename: String, pattern: String) -> Bool {
        let name = filename.lowercased()
        let pat = pattern.lowercased()

        guard pat.contains("*") else { return name == pat }

        // Split on "*". Every literal segment must appear in order; the first
        // segment must be a prefix and the last a suffix.
        let segments = pat.components(separatedBy: "*")
        var cursor = name.startIndex

        for (index, segment) in segments.enumerated() {
            if segment.isEmpty { continue }

            if index == 0 {
                guard name.hasPrefix(segment) else { return false }
                cursor = name.index(cursor, offsetBy: segment.count)
            } else if index == segments.count - 1 {
                guard name[cursor...].hasSuffix(segment) else { return false }
            } else {
                guard let range = name.range(of: segment, range: cursor..<name.endIndex) else { return false }
                cursor = range.upperBound
            }
        }
        return true
    }
}
