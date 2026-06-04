import Testing
@testable import ConfigKit

@Suite struct PlistConfigFormatTests {
    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Name</key>
        <string>Lume</string>
        <key>Version</key>
        <integer>3</integer>
        <key>Enabled</key>
        <true/>
        <key>Tags</key>
        <array>
            <string>a</string>
            <string>b</string>
        </array>
    </dict>
    </plist>
    """

    @Test func parsesDictPreservingKeyOrder() throws {
        let value = try PlistConfigFormat.parse(sample)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)"); return
        }
        #expect(entries.map(\.key) == ["Name", "Version", "Enabled", "Tags"])
        #expect(entries[0].value == .string("Lume"))
        #expect(entries[1].value == .number("3"))
        #expect(entries[2].value == .bool(true))
        #expect(entries[3].value == .array([.string("a"), .string("b")]))
    }

    @Test func roundTripsThroughSerialize() throws {
        let value = try PlistConfigFormat.parse(sample)
        let out = try PlistConfigFormat.serialize(value)
        #expect(try PlistConfigFormat.parse(out) == value)
    }

    @Test func throwsOnMalformedPlist() {
        #expect(throws: ConfigParseError.self) {
            try PlistConfigFormat.parse("<plist><dict><key>x</key></dict></plist>")
        }
    }
}
