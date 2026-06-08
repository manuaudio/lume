import Testing
import Foundation
@testable import LumeKit

/// Write `contents` to a uniquely-named file in a temp dir, return its URL.
private func tempFile(_ name: String, _ contents: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctxasm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func assembleXMLWrapsEachFile() throws {
    let a = try tempFile("CLAUDE.md", "# Rules\nUse TDD")
    let b = try tempFile("config.json", "{\"k\":1}")
    let result = ContextAssembler.assemble([a, b], format: .xml)

    #expect(result.fileCount == 2)
    #expect(result.unreadable.isEmpty)
    #expect(result.text.hasPrefix("<documents>"))
    #expect(result.text.hasSuffix("</documents>"))
    #expect(result.text.contains("<document path=\"\(ContextAssembler.displayPath(a))\">"))
    #expect(result.text.contains("# Rules\nUse TDD"))
    #expect(result.text.contains("{\"k\":1}"))
}

@Test func assembleMarkdownInfersLanguageAndHeading() throws {
    let py = try tempFile("script.py", "print('hi')")
    let result = ContextAssembler.assemble([py], format: .markdown)

    #expect(result.text.contains("## \(ContextAssembler.displayPath(py))"))
    #expect(result.text.contains("```python"))
    #expect(result.text.contains("print('hi')"))
}

@Test func markdownFenceLongerThanContentBackticks() throws {
    let md = try tempFile("CLAUDE.md", "Example:\n```\ncode\n```\n")
    let result = ContextAssembler.assemble([md], format: .markdown)
    #expect(result.text.contains("````markdown"))
}

@Test func tokenEstimateIsCharsOverFour() throws {
    let f = try tempFile("a.txt", "abcdefgh")
    let result = ContextAssembler.assemble([f], format: .xml)
    #expect(result.tokenEstimate == Int(ceil(Double(result.text.count) / 4.0)))
    #expect(result.tokenEstimate > 0)
}

@Test func unreadableFilesAreCollectedNotDropped() throws {
    let good = try tempFile("good.md", "hello")
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).md")
    let result = ContextAssembler.assemble([good, missing], format: .xml)

    #expect(result.fileCount == 1)
    #expect(result.unreadable == [missing])
    #expect(result.text.contains("hello"))
}

@Test func emptyInputYieldsEmptyResult() {
    let result = ContextAssembler.assemble([], format: .xml)
    #expect(result.text.isEmpty)
    #expect(result.tokenEstimate == 0)
    #expect(result.fileCount == 0)
}

@Test func displayPathAbbreviatesHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let url = home.appendingPathComponent("proj/CLAUDE.md")
    #expect(ContextAssembler.displayPath(url) == "~/proj/CLAUDE.md")
}

@Test func xmlEscapesBodySoNestedTagsDontBreakStructure() throws {
    let f = try tempFile("notes.md", "Use a </document> tag & <thing>")
    let result = ContextAssembler.assemble([f], format: .xml)
    #expect(!result.text.contains("</document> tag"))        // raw closing tag must not survive
    #expect(result.text.contains("&lt;/document&gt; tag &amp; &lt;thing&gt;"))
    #expect(result.text.hasSuffix("</document>\n</documents>"))  // only the real closer remains
}
