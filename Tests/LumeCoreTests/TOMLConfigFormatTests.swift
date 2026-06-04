import Testing
@testable import ConfigKit

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
}
