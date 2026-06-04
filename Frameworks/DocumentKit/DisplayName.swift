import Foundation

/// Display-only naming helper. Derives a parent-folder label for a curated set
/// of recurring, ambiguous filenames (many `.env`, many `CLAUDE.md`) so Pinned
/// rows are distinguishable at a glance. Pure logic — never touches the file
/// system or SwiftData, and never renames anything on disk.
public enum DisplayName {

    /// Basenames (lowercased) that are too generic to identify on their own.
    /// `.env` / `.env.*` are handled separately by prefix.
    private static let ambiguousNames: Set<String> = [
        "claude.md", "agents.md", "gemini.md", "readme.md",
        "index.html", "index.md", "package.json", "dockerfile",
        "docker-compose.yml", "makefile", ".gitignore",
    ]

    /// True when `filename` is one of the curated ambiguous names, matched
    /// case-insensitively. Also matches `.env` and any `.env.*` variant
    /// (e.g. `.env.local`, `.env.production`).
    public static func isAmbiguous(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        return ambiguousNames.contains(lower)
    }

    /// The parent-folder name to show in place of an ambiguous filename, or
    /// `nil` when the file isn't ambiguous (caller should fall back to the
    /// filename). Computed at render time; never persisted.
    public static func autoName(for url: URL) -> String? {
        guard isAmbiguous(url.lastPathComponent) else { return nil }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
