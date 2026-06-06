import Testing
import Foundation
@testable import LumeKit

struct FileKindTests {
    @Test func markdownExtensions() {
        #expect(FileKind(url: URL(fileURLWithPath: "/a/readme.md")) == .markdown)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/NOTES.MARKDOWN")) == .markdown)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/x.mkd")) == .markdown)
    }

    @Test func plainTextAndSourceAreText() {
        #expect(FileKind(url: URL(fileURLWithPath: "/a/notes.txt")) == .text)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/Main.swift")) == .text)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/data.json")) == .text)
    }

    @Test func binaryAndUnknownAreOther() {
        #expect(FileKind(url: URL(fileURLWithPath: "/a/pic.png")) == .other)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/archive.zip")) == .other)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/noext")) == .other)
    }
}
