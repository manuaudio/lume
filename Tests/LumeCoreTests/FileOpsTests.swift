import Testing
import Foundation
@testable import FileSystemKit

@Suite struct FileOpsTests {
    let dir = URL(fileURLWithPath: "/tmp/lume")

    @Test func uniqueChildReturnsBaseWhenFree() {
        let url = FileOps.uniqueChild(in: dir, base: "untitled folder") { _ in false }
        #expect(url.lastPathComponent == "untitled folder")
    }

    @Test func uniqueChildAppendsNumberOnCollision() {
        let taken: Set<String> = ["/tmp/lume/untitled folder", "/tmp/lume/untitled folder 2"]
        let url = FileOps.uniqueChild(in: dir, base: "untitled folder") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "untitled folder 3")
    }

    @Test func uniqueChildKeepsExtensionWhenNumbering() {
        let taken: Set<String> = ["/tmp/lume/notes.md"]
        let url = FileOps.uniqueChild(in: dir, base: "notes", ext: "md") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "notes 2.md")
    }

    @Test func duplicateURLAddsCopySuffix() {
        let src = URL(fileURLWithPath: "/tmp/lume/report.pdf")
        let url = FileOps.duplicateURL(for: src) { _ in false }
        #expect(url.lastPathComponent == "report copy.pdf")
    }

    @Test func duplicateURLNumbersRepeatedCopies() {
        let src = URL(fileURLWithPath: "/tmp/lume/report.pdf")
        let taken: Set<String> = ["/tmp/lume/report copy.pdf"]
        let url = FileOps.duplicateURL(for: src) { taken.contains($0.path) }
        #expect(url.lastPathComponent == "report copy 2.pdf")
    }

    @Test func duplicateURLHandlesNoExtension() {
        let src = URL(fileURLWithPath: "/tmp/lume/Makefile")
        let url = FileOps.duplicateURL(for: src) { _ in false }
        #expect(url.lastPathComponent == "Makefile copy")
    }
}
