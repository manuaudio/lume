import Testing
@testable import LumeCore

@Test func parsesEntriesCommentsAndBlanks() {
    let text = """
    # API keys
    OPENAI_API_KEY=sk-abc123

    EMPTY=
    """
    let lines = EnvFile.parse(text)
    #expect(lines.count == 4)
    #expect(lines[0] == .comment("# API keys"))
    #expect(lines[1] == .entry(EnvEntry(key: "OPENAI_API_KEY", value: "sk-abc123")))
    #expect(lines[2] == .blank)
    #expect(lines[3] == .entry(EnvEntry(key: "EMPTY", value: "")))
}

@Test func keyAndValueAreTrimmedButValueKeepsInnerEquals() {
    let lines = EnvFile.parse("  URL = https://x.com/a=b ")
    #expect(lines == [.entry(EnvEntry(key: "URL", value: "https://x.com/a=b"))])
}

@Test func masksValueWithDotsCappedAtTwentyFour() {
    #expect(EnvFile.mask("secret") == "••••••")          // 6
    #expect(EnvFile.mask("") == "")
    let long = String(repeating: "x", count: 50)
    #expect(EnvFile.mask(long) == String(repeating: "•", count: 24))
}

@Test func entriesConvenienceReturnsOnlyEntries() {
    let lines = EnvFile.parse("# c\nA=1\nB=2")
    #expect(EnvFile.entries(from: lines) == [
        EnvEntry(key: "A", value: "1"),
        EnvEntry(key: "B", value: "2"),
    ])
}
