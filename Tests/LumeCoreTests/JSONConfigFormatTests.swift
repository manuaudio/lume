import Testing
@testable import ConfigKit

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
}
