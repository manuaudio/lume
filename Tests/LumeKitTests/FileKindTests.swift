import Testing
import Foundation
@testable import LumeKit

struct FileKindTests {
    @Test func markdownByExtension() {
        #expect(FileKind.detect(filename: "readme.md") == .markdown)
        #expect(FileKind.detect(filename: "NOTES.MARKDOWN") == .markdown)
    }

    @Test func envByNamePrefix() {
        #expect(FileKind.detect(filename: ".env") == .env)
        #expect(FileKind.detect(filename: ".env.local") == .env)
    }

    @Test func codeSourceFiles() {
        #expect(FileKind.detect(filename: "Main.swift") == .code)
        #expect(FileKind.detect(filename: "data.json") == .code)
        #expect(FileKind.detect(filename: "notes.txt") == .code)
    }

    @Test func mediaAndDocs() {
        #expect(FileKind.detect(filename: "pic.png") == .image)
        #expect(FileKind.detect(filename: "paper.pdf") == .pdf)
        #expect(FileKind.detect(filename: "page.html") == .html)
        #expect(FileKind.detect(filename: "report.docx") == .previewable)
    }

    @Test func unknownIsUnsupported() {
        #expect(FileKind.detect(filename: "archive.zip") == .unsupported)
        #expect(FileKind.detect(filename: "noext") == .unsupported)
    }
}
