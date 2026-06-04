import Testing
import Foundation
@testable import DocumentKit

@Test func pathExportEmptyInputIsEmptyString() {
    #expect(PathExport.clipboardString(for: []) == "")
}

@Test func pathExportSinglePathHasNoTrailingNewline() {
    let url = URL(fileURLWithPath: "/Users/manu/notes.md")
    #expect(PathExport.clipboardString(for: [url]) == "/Users/manu/notes.md")
}

@Test func pathExportJoinsWithNewlinesPreservingOrder() {
    let urls = [
        URL(fileURLWithPath: "/a/z.txt"),
        URL(fileURLWithPath: "/a/m.txt"),
        URL(fileURLWithPath: "/a/b.txt"),
    ]
    #expect(PathExport.clipboardString(for: urls) == "/a/z.txt\n/a/m.txt\n/a/b.txt")
}
