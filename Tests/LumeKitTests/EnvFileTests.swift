import Testing
@testable import LumeKit

@Suite struct EnvFileTests {
    @Test func parsesEntriesCommentsAndBlanks() {
        let input = "# config\nHOST=localhost\n\nexport PORT=5432\nNAME=\"lume app\"\nTOKEN='s3cret'"
        let lines = EnvFile.parse(input)
        #expect(lines[0] == .comment("# config"))
        #expect(lines[1] == .entry(EnvEntry(key: "HOST", value: "localhost")))
        #expect(lines[2] == .blank)
        #expect(EnvFile.entries(from: lines) == [
            EnvEntry(key: "HOST", value: "localhost"),
            EnvEntry(key: "PORT", value: "5432"),
            EnvEntry(key: "NAME", value: "lume app"),
            EnvEntry(key: "TOKEN", value: "s3cret"),
        ])
    }

    @Test func parsesCRLFFilesWithoutCarriageReturnLeakage() {
        // Fails before the fix: split on "\n" left a trailing \r on every line,
        // so values gained \r, quote-stripping failed, and the blank line
        // (containing just \r) misclassified.
        let lines = EnvFile.parse("A=1\r\nB=\"two\"\r\n\r\n# note\r\nC=3")
        #expect(EnvFile.entries(from: lines) == [
            EnvEntry(key: "A", value: "1"),
            EnvEntry(key: "B", value: "two"),
            EnvEntry(key: "C", value: "3"),
        ])
        #expect(lines[2] == .blank)
        #expect(lines[3] == .comment("# note"))
    }

    @Test func lineWithoutEqualsBecomesComment() {
        #expect(EnvFile.parse("not an assignment") == [.comment("not an assignment")])
    }

    @Test func stripsOnlyMatchingSurroundingQuotes() {
        #expect(EnvFile.stripSurroundingQuotes(#""x""#) == "x")
        #expect(EnvFile.stripSurroundingQuotes("'x'") == "x")
        #expect(EnvFile.stripSurroundingQuotes(#""x'"#) == #""x'"#)
        #expect(EnvFile.stripSurroundingQuotes(#"""#) == #"""#)
    }

    @Test func masksCapAtTwentyFourDots() {
        #expect(EnvFile.mask("abc") == "•••")
        #expect(EnvFile.mask(String(repeating: "x", count: 100)).count == 24)
    }
}
