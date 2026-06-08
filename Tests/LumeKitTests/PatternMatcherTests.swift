import Testing
@testable import LumeKit

@Test func exactMatchIsCaseInsensitive() {
    #expect(PatternMatcher.matches(filename: "CLAUDE.md", pattern: "claude.md"))
    #expect(PatternMatcher.matches(filename: "claude.md", pattern: "CLAUDE.md"))
}

@Test func exactNonMatch() {
    #expect(!PatternMatcher.matches(filename: "README.md", pattern: "CLAUDE.md"))
}

@Test func suffixGlobMatches() {
    #expect(PatternMatcher.matches(filename: "prod.env", pattern: "*.env"))
    #expect(PatternMatcher.matches(filename: ".env", pattern: "*.env"))
    #expect(!PatternMatcher.matches(filename: "env.txt", pattern: "*.env"))
}

@Test func prefixGlobMatches() {
    #expect(PatternMatcher.matches(filename: ".env.local", pattern: ".env*"))
    #expect(!PatternMatcher.matches(filename: "prod.env", pattern: ".env*"))
}

@Test func bareStarMatchesEverything() {
    #expect(PatternMatcher.matches(filename: "anything.json", pattern: "*"))
}

@Test func matchesAnyAcrossPatterns() {
    let patterns = ["CLAUDE.md", "*.env"]
    #expect(PatternMatcher.matchesAny(filename: "CLAUDE.md", patterns: patterns))
    #expect(PatternMatcher.matchesAny(filename: "prod.env", patterns: patterns))
    #expect(!PatternMatcher.matchesAny(filename: "main.swift", patterns: patterns))
}
