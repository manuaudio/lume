import Testing
@testable import LumeKit

@Suite struct JSONConfigFormatTests {
    @Test func parsesObjectPreservingKeyOrder() throws {
        let value = try JSONConfigFormat.parse(#"{"b": 1, "a": 2, "c": 3}"#)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)")
            return
        }
        #expect(entries.map(\.key) == ["b", "a", "c"])
    }

    @Test func roundTripsNestedConfigThroughSerialize() throws {
        let src = #"{"name": "lume", "nested": {"on": true, "count": 3, "ratio": 1.5}, "tags": ["a", "b"], "empty": null}"#
        let value = try JSONConfigFormat.parse(src)
        let out = try JSONConfigFormat.serialize(value)
        #expect(try JSONConfigFormat.parse(out) == value)
    }

    @Test func serializesWithTwoSpaceIndentInOrder() throws {
        let value = ConfigValue.object([
            ConfigEntry(key: "z", value: .number("1")),
            ConfigEntry(key: "a", value: .array([.string("x"), .bool(false)])),
        ])
        let out = try JSONConfigFormat.serialize(value)
        #expect(out == """
        {
          "z": 1,
          "a": [
            "x",
            false
          ]
        }
        """)
    }

    @Test func preservesStringEscapesAcrossRoundTrip() throws {
        let value = try JSONConfigFormat.parse(#"{"path": "a\tb\nc", "quote": "say \"hi\""}"#)
        let out = try JSONConfigFormat.serialize(value)
        #expect(try JSONConfigFormat.parse(out) == value)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: ConfigParseError.self) {
            try JSONConfigFormat.parse(#"{"a": }"#)
        }
    }

    // Formats without native date/data types degrade the new cases to plain
    // strings, never crash.
    @Test func serializesDateAndDataCasesAsStrings() throws {
        let value = ConfigValue.object([
            ConfigEntry(key: "d", value: .date("2024-06-01")),
            ConfigEntry(key: "b", value: .data("aGVsbG8=")),
        ])
        let out = try JSONConfigFormat.serialize(value)
        #expect(try JSONConfigFormat.parse(out) == .object([
            ConfigEntry(key: "d", value: .string("2024-06-01")),
            ConfigEntry(key: "b", value: .string("aGVsbG8=")),
        ]))
    }

    @Test func parsesSurrogatePairEscapes() throws {
        // Fails before the fix: U+1F600 escapes as 😀 (what
        // JSONSerialization emits for emoji) and the parser threw on the
        // high surrogate.
        let value = try JSONConfigFormat.parse(#"{"emoji": "\uD83D\uDE00"}"#)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)")
            return
        }
        #expect(entries[0].value == .string("😀"))
        // And the parsed value survives a serialize → parse cycle.
        let out = try JSONConfigFormat.serialize(value)
        #expect(try JSONConfigFormat.parse(out) == value)
    }

    @Test func throwsOnLoneOrMalformedSurrogates() {
        // Lone high surrogate at end of string.
        #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83D""#) }
        // Lone low surrogate.
        #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uDE00""#) }
        // High surrogate followed by a plain character.
        #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83Dx""#) }
        // High surrogate followed by a non-\u escape.
        #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83D\n""#) }
        // High surrogate followed by another high surrogate.
        #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83D\uD83D""#) }
    }

    @Test func bmpEscapesStillParse() throws {
        #expect(try JSONConfigFormat.parse(#""é""#) == .string("é"))
    }

    @Test func rejectsGarbageNumberLexemes() {
        // Fails before the fix: the charset scan accepted these and serialize
        // would emit invalid JSON.
        for bad in ["1.2.3", "+1", "01", ".5", "1.", "1e", "1e+", "--1", "0x10", "1e5e5", "-"] {
            #expect(throws: ConfigParseError.self) {
                try JSONConfigFormat.parse(bad)
            }
        }
    }

    @Test func acceptsValidNumberLexemesUnchanged() throws {
        #expect(try JSONConfigFormat.parse("0") == .number("0"))
        #expect(try JSONConfigFormat.parse("123") == .number("123"))
        #expect(try JSONConfigFormat.parse("0.1") == .number("0.1"))
        #expect(try JSONConfigFormat.parse("-0.5e+10") == .number("-0.5e+10"))
    }

    @Test func throwsInsteadOfCrashingOnDeepNesting() {
        // Fails (by crashing) before the fix: 10k nested arrays overflow the stack.
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(deep) }
    }

    @Test func allowsReasonableNestingDepth() throws {
        let ok = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: Never.self) { try JSONConfigFormat.parse(ok) }
    }
}
