import Foundation

/// Exports file URLs as the clipboard text an LLM hand-off expects: the absolute
/// POSIX path of each URL, one per line, in the given order (mirrors Finder's
/// "Copy as Pathname"). Empty input yields an empty string.
public enum PathExport {
    public static func clipboardString(for urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }
}
