import Testing
import Foundation
@testable import LumeKit

/// Pure collision-avoidance naming for New Folder / Duplicate. `exists` is
/// injected so these never touch the disk.
@Suite struct FileOpsTests {
    private let parent = URL(fileURLWithPath: "/work")

    @Test func uniqueChildNoCollision() {
        let url = FileOps.uniqueChild(in: parent, base: "untitled folder", exists: { _ in false })
        #expect(url.path == "/work/untitled folder")
    }

    @Test func uniqueChildAppendsCounter() {
        let taken: Set<String> = ["/work/untitled folder", "/work/untitled folder 2"]
        let url = FileOps.uniqueChild(in: parent, base: "untitled folder",
                                      exists: { taken.contains($0.path) })
        #expect(url.path == "/work/untitled folder 3")
    }

    @Test func uniqueChildWithExtension() {
        let taken: Set<String> = ["/work/note.txt"]
        let url = FileOps.uniqueChild(in: parent, base: "note", ext: "txt",
                                      exists: { taken.contains($0.path) })
        #expect(url.path == "/work/note 2.txt")
    }

    @Test func duplicateURLAddsCopySuffix() {
        let src = URL(fileURLWithPath: "/work/report.md")
        let url = FileOps.duplicateURL(for: src, exists: { _ in false })
        #expect(url.path == "/work/report copy.md")
    }

    @Test func duplicateURLCountsExistingCopies() {
        let src = URL(fileURLWithPath: "/work/report.md")
        let taken: Set<String> = ["/work/report copy.md"]
        let url = FileOps.duplicateURL(for: src, exists: { taken.contains($0.path) })
        #expect(url.path == "/work/report copy 2.md")
    }

    @Test func duplicateURLPreservesNoExtension() {
        let src = URL(fileURLWithPath: "/work/Makefile")
        let url = FileOps.duplicateURL(for: src, exists: { _ in false })
        #expect(url.path == "/work/Makefile copy")
    }
}
