import Testing
import Foundation
@testable import DocumentKit

@Test func breadcrumbSegmentsUnderHomeUseTilde() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let current = URL(fileURLWithPath: "/Users/manu/Documents/Notes")
    let segs = Breadcrumb.segments(for: current, home: home)

    #expect(segs.map(\.label) == ["~", "Documents", "Notes"])
    #expect(segs.map(\.url.path) ==
        ["/Users/manu", "/Users/manu/Documents", "/Users/manu/Documents/Notes"])
}

@Test func breadcrumbOutsideHomeStartsAtRoot() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let current = URL(fileURLWithPath: "/tmp/work")
    let segs = Breadcrumb.segments(for: current, home: home)

    #expect(segs.map(\.label) == ["/", "tmp", "work"])
}

@Test func breadcrumbAtHomeIsSingleSegment() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let segs = Breadcrumb.segments(for: home, home: home)
    #expect(segs.map(\.label) == ["~"])
}

// Regression: a non-file (relative) URL's `deletingLastPathComponent()` prepends
// "../" forever and never reaches a fixed point, so the old `while true` loop
// grew `urls` unbounded → 31 GB footprint → macOS CPU-resource kill. The loop
// must terminate and return a bounded result for such a URL.
@Test func breadcrumbRelativeURLTerminatesAndIsBounded() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let relative = URL(string: "Documents")!   // isFileURL == false
    #expect(relative.isFileURL == false)        // guards the precondition of this test

    let segs = Breadcrumb.segments(for: relative, home: home)

    #expect(segs.count == 1)
    #expect(segs.first?.label == "Documents")
}

// Backstop: even a deeply nested absolute path stays well under the iteration
// cap and produces the expected root → current chain.
@Test func breadcrumbDeepAbsolutePathIsBounded() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let deep = URL(fileURLWithPath: "/a/b/c/d/e/f/g")
    let segs = Breadcrumb.segments(for: deep, home: home)
    #expect(segs.map(\.label) == ["/", "a", "b", "c", "d", "e", "f", "g"])
    #expect(segs.count <= 64)
}
