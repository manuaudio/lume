import Testing
import Foundation
@testable import LumeKit

@Test func pathPatternMatchesAtAnyDepth() {
    #expect(ConfigPathMatcher.matches(path: "/proj/.claude/settings.json", pattern: ".claude/settings.json"))
    #expect(ConfigPathMatcher.matches(path: "/a/b/c/.claude/settings.json", pattern: ".claude/settings.json"))
}

@Test func pathPatternRequiresTheParentSegment() {
    // A bare settings.json not under .claude must NOT match.
    #expect(!ConfigPathMatcher.matches(path: "/proj/settings.json", pattern: ".claude/settings.json"))
    // settings.json under a different dir must NOT match.
    #expect(!ConfigPathMatcher.matches(path: "/proj/.vscode/settings.json", pattern: ".claude/settings.json"))
}

@Test func pathPatternLastSegmentSupportsGlob() {
    #expect(ConfigPathMatcher.matches(path: "/p/.cursor/rules/style.mdc", pattern: ".cursor/rules/*.mdc"))
    #expect(!ConfigPathMatcher.matches(path: "/p/.cursor/rules/style.txt", pattern: ".cursor/rules/*.mdc"))
    // Wrong parent chain must not match.
    #expect(!ConfigPathMatcher.matches(path: "/p/rules/style.mdc", pattern: ".cursor/rules/*.mdc"))
}

@Test func pathPatternIsCaseInsensitive() {
    #expect(ConfigPathMatcher.matches(path: "/p/.GitHub/COPILOT-instructions.md",
                                      pattern: ".github/copilot-instructions.md"))
}

@Test func matchesAnyChecksEveryPattern() {
    let patterns = [".claude/settings.json", ".vscode/mcp.json"]
    #expect(ConfigPathMatcher.matchesAny(path: "/p/.vscode/mcp.json", patterns: patterns))
    #expect(!ConfigPathMatcher.matchesAny(path: "/p/.idea/mcp.json", patterns: patterns))
}
