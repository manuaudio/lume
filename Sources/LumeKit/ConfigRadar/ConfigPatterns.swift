import Foundation

/// Filename globs (case-insensitive, matched by `PatternMatcher`) for the
/// AI-coding config files Config Radar hunts. Filename-only — path-scoped
/// configs like `.claude/settings.json` are out of scope for v1.
public enum ConfigPatterns {
    public static let aiConfig: [String] = [
        "CLAUDE.md",
        "AGENTS.md",
        "GEMINI.md",
        ".env",
        ".env.*",
        ".mcp.json",
        ".cursorrules",
    ]
}
