import Foundation

/// The AI-coding config files Config Radar hunts.
///
/// `aiConfig` holds filename globs (case-insensitive, matched against a file's
/// name only). `aiConfigPaths` holds path-tail patterns for configs that are
/// only meaningful inside a specific directory (e.g. `.claude/settings.json`),
/// matched with `ConfigPathMatcher`.
public enum ConfigPatterns {
    public static let aiConfig: [String] = [
        // Agent instruction files
        "CLAUDE.md",
        "CLAUDE.local.md",
        "AGENTS.md",
        "GEMINI.md",
        ".cursorrules",
        ".windsurfrules",
        ".clinerules",
        ".goosehints",
        ".aider.conf.yml",
        ".continuerc",
        // Emerging LLM-context standard
        "llms.txt",
        "llms-full.txt",
        // MCP + environment / secrets
        ".mcp.json",
        ".env",
        ".env.*",
        // Toolchain version pins (drift across machines, break builds)
        ".nvmrc",
        ".node-version",
        ".python-version",
        ".ruby-version",
        ".tool-versions",
    ]

    /// Path-tail patterns for directory-scoped configs. Last segment is a
    /// filename glob; earlier segments match the file's parent directories.
    public static let aiConfigPaths: [String] = [
        ".claude/settings.json",
        ".claude/settings.local.json",
        ".cursor/rules/*.mdc",
        ".github/copilot-instructions.md",
        ".vscode/mcp.json",
    ]
}
