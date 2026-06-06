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
}
