import Testing
@testable import LumeKit

@Suite struct ConfigRegistryTests {
    @Test func resolvesJSONByExtension() {
        let format = ConfigRegistry.format(forExtension: "JSON")
        #expect(format?.identifier == "json")
    }

    @Test func resolvesAllRegisteredFormats() {
        #expect(ConfigRegistry.format(forExtension: "plist")?.identifier == "plist")
        #expect(ConfigRegistry.format(forExtension: "yaml")?.identifier == "yaml")
        #expect(ConfigRegistry.format(forExtension: "yml")?.identifier == "yaml")
        #expect(ConfigRegistry.format(forExtension: "toml")?.identifier == "toml")
    }

    @Test func returnsNilForUnknownExtension() {
        #expect(ConfigRegistry.format(forExtension: "rtf") == nil)
    }

    @Test func resolvesByFilename() {
        #expect(ConfigRegistry.format(forFilename: "package.json")?.identifier == "json")
        #expect(ConfigRegistry.format(forFilename: "README.md") == nil)
    }
}
