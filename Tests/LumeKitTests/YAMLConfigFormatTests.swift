import Testing
@testable import LumeKit

@Suite struct YAMLConfigFormatTests {
    @Test func parsesMappingPreservingKeyOrder() throws {
        let value = try YAMLConfigFormat.parse("""
        name: lume
        version: 3
        enabled: true
        tags:
          - a
          - b
        """)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)"); return
        }
        #expect(entries.map(\.key) == ["name", "version", "enabled", "tags"])
        #expect(entries[0].value == .string("lume"))
        #expect(entries[1].value == .number("3"))
        #expect(entries[2].value == .bool(true))
        #expect(entries[3].value == .array([.string("a"), .string("b")]))
    }

    @Test func roundTripsThroughSerialize() throws {
        let src = """
        host: localhost
        port: 5432
        debug: false
        nested:
          retries: 3
          tags:
            - x
            - y
        """
        let value = try YAMLConfigFormat.parse(src)
        let out = try YAMLConfigFormat.serialize(value)
        #expect(try YAMLConfigFormat.parse(out) == value)
    }

    @Test func throwsOnMalformedYAML() {
        #expect(throws: ConfigParseError.self) {
            try YAMLConfigFormat.parse("key: [unclosed")
        }
    }

    @Test func quotesStringsThatWouldRetypeOnRoundTrip() throws {
        // Fails before the fix: "1.0" re-parses as .number, "true"/"no" as .bool,
        // "null"/"" as .null, "0x1F" as .number.
        let value = ConfigValue.object([
            ConfigEntry(key: "version", value: .string("1.0")),
            ConfigEntry(key: "flag", value: .string("true")),
            ConfigEntry(key: "negative", value: .string("no")),
            ConfigEntry(key: "nothing", value: .string("null")),
            ConfigEntry(key: "hex", value: .string("0x1F")),
            ConfigEntry(key: "empty", value: .string("")),
        ])
        let out = try YAMLConfigFormat.serialize(value)
        #expect(try YAMLConfigFormat.parse(out) == value)
        #expect(out.contains(#"version: "1.0""#))
    }

    @Test func unambiguousStringsStayUnquoted() throws {
        let value = ConfigValue.object([ConfigEntry(key: "name", value: .string("lume"))])
        let out = try YAMLConfigFormat.serialize(value)
        #expect(out.contains("name: lume"))
        #expect(!out.contains(#""lume""#))
    }

    @Test func timestampLikeStringsRoundTripUnquoted() throws {
        let value = try YAMLConfigFormat.parse("released: 2024-06-01")
        let out = try YAMLConfigFormat.serialize(value)
        #expect(out.contains("released: 2024-06-01"))
        #expect(!out.contains(#""2024-06-01""#))
        #expect(try YAMLConfigFormat.parse(out) == value)
    }
}
