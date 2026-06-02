import Testing
import Foundation
@testable import LumeCore

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
