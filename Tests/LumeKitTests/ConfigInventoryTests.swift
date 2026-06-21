import Testing
import Foundation
@testable import LumeKit

private func file(_ id: SourceID, _ path: String) -> ConfigFile {
    ConfigFile(ref: ResourceRef(sourceID: id, path: path), size: nil)
}

@Test func groupsSameFilenameAcrossSources() {
    let files = [
        file(.local, "/a/CLAUDE.md"),
        file(.ssh(alias: "prod"), "/srv/CLAUDE.md"),
    ]
    let groups = ConfigInventory.group(files)
    #expect(groups.count == 1)
    #expect(groups[0].key == "claude.md")
    #expect(groups[0].copies.count == 2)
}

@Test func separatesDistinctFilenames() {
    let files = [file(.local, "/a/CLAUDE.md"), file(.local, "/a/.env")]
    let groups = ConfigInventory.group(files)
    #expect(groups.count == 2)
}

@Test func groupingIsCaseInsensitiveByFilename() {
    let files = [file(.local, "/a/CLAUDE.md"), file(.local, "/b/claude.md")]
    let groups = ConfigInventory.group(files)
    #expect(groups.count == 1)
    #expect(groups[0].copies.count == 2)
}

@Test func preservesFirstAppearanceOrder() {
    let files = [file(.local, "/a/.env"), file(.local, "/a/CLAUDE.md")]
    let groups = ConfigInventory.group(files)
    #expect(groups.map(\.key) == [".env", "claude.md"])
}
