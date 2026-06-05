import Testing
@testable import SelectionKit

@Suite struct GroupRowTests {

    // MARK: group header ids

    @Test func groupHeaderIDRoundTrips() {
        let id: String = GroupRowID.header(tagName: "project-x")
        #expect(id == "group|g|project-x")
        let decoded = GroupRowID.decode(id)
        #expect(decoded == .header(tagName: "project-x"))
    }

    @Test func groupHeaderIDPreservesPipeInTagName() {
        // Tag names can theoretically contain "|"; the header has exactly one
        // payload field, so split with maxSplits:2 keeps the remainder intact.
        let id: String = GroupRowID.header(tagName: "a|b")
        #expect(GroupRowID.decode(id) == .header(tagName: "a|b"))
    }

    // MARK: file-under-group ids

    @Test func groupFileIDRoundTrips() {
        let id: String = GroupRowID.file(tagName: "project-x", path: "/Users/me/a.md")
        #expect(id == "groupfile|f|project-x|/Users/me/a.md")
        #expect(GroupRowID.decode(id) == .file(tagName: "project-x", path: "/Users/me/a.md"))
    }

    @Test func groupFileIDPreservesPipeInPath() {
        // The PATH (last field) may contain "|"; only the first 3 separators are
        // structural, so the path remainder is reassembled verbatim.
        let id: String = GroupRowID.file(tagName: "grp", path: "/x/a|b.md")
        #expect(GroupRowID.decode(id) == .file(tagName: "grp", path: "/x/a|b.md"))
    }

    @Test func sameFileUnderTwoGroupsHasDistinctIDs() {
        let a: String = GroupRowID.file(tagName: "alpha", path: "/x/a.md")
        let b: String = GroupRowID.file(tagName: "beta", path: "/x/a.md")
        #expect(a != b)
    }

    // MARK: cross-grammar isolation (browser/pinned ids are NOT group ids)

    @Test func decodeRejectsBrowserAndPinnedIDs() {
        #expect(GroupRowID.decode("browser|f|/x/a.md") == nil)
        #expect(GroupRowID.decode("pinned|d|/x/dir") == nil)
        #expect(GroupRowID.decode("garbage") == nil)
    }

    @Test func fileURLForGroupFileID() {
        // A groupfile id resolves to its real file URL (drives Copy Paths / open).
        let id: String = GroupRowID.file(tagName: "g", path: "/x/a.md")
        #expect(GroupRowID.fileURL(forID: id)?.path == "/x/a.md")
        // A header id has no file URL.
        #expect(GroupRowID.fileURL(forID: GroupRowID.header(tagName: "g")) == nil)
        // A browser id has no GROUP file URL (handled by SidebarRow.decode instead).
        #expect(GroupRowID.fileURL(forID: "browser|f|/x/a.md") == nil)
    }
}
