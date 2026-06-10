import Foundation
import Testing
@testable import LumeKit

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

    @Test func roundTripsDataAndDateAsNativeTags() throws {
        // Fails before the fix: <date>/<data> parsed to .string and re-serialized
        // as <string>, silently retyping the plist on save.
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Stamp</key>
            <date>2024-06-01T07:32:00Z</date>
            <key>Blob</key>
            <data>aGVsbG8=</data>
        </dict>
        </plist>
        """
        let value = try PlistConfigFormat.parse(sample)
        guard case let .object(entries) = value else {
            Issue.record("expected object, got \(value)"); return
        }
        #expect(entries[0].value == .date("2024-06-01T07:32:00Z"))
        #expect(entries[1].value == .data("aGVsbG8="))
        let out = try PlistConfigFormat.serialize(value)
        #expect(out.contains("<date>2024-06-01T07:32:00Z</date>"))
        #expect(out.contains("<data>aGVsbG8=</data>"))
        #expect(try PlistConfigFormat.parse(out) == value)
        // The emitted plist must stay readable by Apple's own parser, with types intact.
        let plist = try PropertyListSerialization.propertyList(
            from: Data(out.utf8), format: nil
        )
        let dict = try #require(plist as? [String: Any])
        #expect(dict["Stamp"] is Date)
        #expect(dict["Blob"] is Data)
    }

    @Test func preservesCDATAContent() throws {
        // Fails before the fix: missing foundCDATA handler parsed the string to ""
        // and saving deleted the content.
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Story</key>
            <string><![CDATA[a <b> & c]]></string>
        </dict>
        </plist>
        """
        let value = try PlistConfigFormat.parse(sample)
        #expect(value == .object([ConfigEntry(key: "Story", value: .string("a <b> & c"))]))
        // Round-trip re-escapes with entities instead of CDATA — content survives.
        let out = try PlistConfigFormat.serialize(value)
        #expect(try PlistConfigFormat.parse(out) == value)
    }
}
