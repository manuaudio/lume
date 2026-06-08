import Testing
import Foundation
@testable import LumeKit

@Test func promptStringWrapsPaths() {
    let urls = [URL(fileURLWithPath: "/a/CLAUDE.md"), URL(fileURLWithPath: "/b/CLAUDE.md")]
    #expect(PathExport.promptString(for: urls) == "Improve these files:\n/a/CLAUDE.md\n/b/CLAUDE.md")
}

@Test func promptStringEmptyForNoURLs() {
    #expect(PathExport.promptString(for: []) == "")
}
