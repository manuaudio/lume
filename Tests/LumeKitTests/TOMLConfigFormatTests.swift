import Testing
@testable import LumeKit

@Suite struct TOMLConfigFormatTests {
    // NOTE: TOMLKit (toml++) exposes table keys alphabetically sorted, not in
    // source order, so we verify type mapping by key lookup. Key order is stable
    // (sorted) across a round-trip; structured edits re-sort keys — a documented
    // TOML limitation alongside comment loss.
    @Test func mapsScalarTypesByKey() throws {
        let value = try TOMLConfigFormat.parse("""
        name = "lume"
        version = 3
        ratio = 1.5
        enabled = true
        tags = ["a", "b"]
        """)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)"); return
        }
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        #expect(entries.map(\.key) == ["enabled", "name", "ratio", "tags", "version"])
        #expect(byKey["name"] == .string("lume"))
        #expect(byKey["version"] == .number("3"))
        #expect(byKey["ratio"] == .number("1.5"))
        #expect(byKey["enabled"] == .bool(true))
        #expect(byKey["tags"] == .array([.string("a"), .string("b")]))
    }

    @Test func roundTripsNestedTable() throws {
        let value = try TOMLConfigFormat.parse("""
        host = "localhost"
        port = 5432

        [database]
        retries = 3
        names = ["x", "y"]
        """)
        let out = try TOMLConfigFormat.serialize(value)
        #expect(try TOMLConfigFormat.parse(out) == value)
    }

    @Test func throwsOnMalformedTOML() {
        #expect(throws: ConfigParseError.self) {
            try TOMLConfigFormat.parse("key = = bad")
        }
    }

    @Test func throwsWhenRootIsNotTable() {
        #expect(throws: ConfigParseError.self) {
            try TOMLConfigFormat.serialize(.string("not a table"))
        }
    }

    @Test func roundTripsDateAndTimeValuesUnquoted() throws {
        // Fails before the fix: dates re-serialized as quoted strings
        // (released = "2024-06-01"), changing the TOML value type on save.
        let value = try TOMLConfigFormat.parse("""
        released = 2024-06-01
        at = 07:32:00
        stamp = 1979-05-27T07:32:00Z
        """)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)"); return
        }
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        #expect(byKey["released"] == .date("2024-06-01"))
        #expect(byKey["at"] == .date("07:32:00"))
        let out = try TOMLConfigFormat.serialize(value)
        #expect(out.contains("released = 2024-06-01"))
        #expect(!out.contains(#""2024-06-01""#))
        #expect(out.contains("at = 07:32:00"))
        #expect(out.contains("stamp = 1979-05-27T07:32:00Z"))
        #expect(try TOMLConfigFormat.parse(out) == value)
    }

    @Test func throwsOnUnparseableNumberLexeme() {
        // Fails before the fix: "1.2.3" silently serialized as 0.
        #expect(throws: ConfigParseError.self) {
            try TOMLConfigFormat.serialize(.object([
                ConfigEntry(key: "n", value: .number("1.2.3")),
            ]))
        }
    }

    @Test func throwsOnUnparseableDateLexeme() {
        #expect(throws: ConfigParseError.self) {
            try TOMLConfigFormat.serialize(.object([
                ConfigEntry(key: "d", value: .date("not-a-date")),
            ]))
        }
    }
}
