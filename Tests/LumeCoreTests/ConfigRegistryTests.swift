import Testing
@testable import ConfigKit

@Suite struct ConfigRegistryTests {
    @Test func resolvesJSONByExtension() {
        let format = ConfigRegistry.format(forExtension: "JSON")
        #expect(format?.identifier == "json")
    }

    @Test func returnsNilForUnknownExtension() {
        #expect(ConfigRegistry.format(forExtension: "rtf") == nil)
    }

    @Test func resolvesByFilename() {
        #expect(ConfigRegistry.format(forFilename: "package.json")?.identifier == "json")
        #expect(ConfigRegistry.format(forFilename: "README.md") == nil)
    }
}
