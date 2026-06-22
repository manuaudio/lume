import Foundation

/// Matches a file's path against a path-tail pattern such as
/// `.claude/settings.json` or `.cursor/rules/*.mdc`.
///
/// The pattern is split on `/`. Its last segment is a filename glob (matched
/// with `PatternMatcher`), and each earlier segment must match the file's
/// immediate ancestor directory names, in order, anchored to the end of the
/// path. So `.cursor/rules/*.mdc` matches `…/.cursor/rules/style.mdc` but not
/// `…/rules/style.mdc`. All matching is case-insensitive (via `PatternMatcher`).
public enum ConfigPathMatcher {
    public static func matches(path: String, pattern: String) -> Bool {
        let patternSegments = pattern.split(separator: "/").map(String.init)
        let pathSegments = path.split(separator: "/").map(String.init)
        guard !patternSegments.isEmpty, pathSegments.count >= patternSegments.count else {
            return false
        }
        let tail = pathSegments.suffix(patternSegments.count)
        for (patternSegment, pathSegment) in zip(patternSegments, tail) {
            guard PatternMatcher.matches(filename: pathSegment, pattern: patternSegment) else {
                return false
            }
        }
        return true
    }

    public static func matchesAny(path: String, patterns: [String]) -> Bool {
        patterns.contains { matches(path: path, pattern: $0) }
    }
}
