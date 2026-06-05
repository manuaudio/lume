import Testing
import SelectionKit

@Suite("GroupRowOrder")
struct GroupRowOrderTests {
    @Test("collapsed groups emit only header ids, in tagName order")
    func collapsedHeadersOnly() {
        let ids = GroupRowOrder.ids(
            tagNames: ["alpha", "beta"],
            expandedGroups: [],
            groupFilePaths: ["alpha": ["/a.md"], "beta": ["/b.md"]])
        #expect(ids == [
            GroupRowID.headerID(tagName: "alpha"),
            GroupRowID.headerID(tagName: "beta"),
        ])
    }

    @Test("an expanded group emits its header then one file id per cached path, in cache order")
    func expandedGroupEmitsFiles() {
        let ids = GroupRowOrder.ids(
            tagNames: ["alpha"],
            expandedGroups: ["alpha"],
            groupFilePaths: ["alpha": ["/z.md", "/a.md"]])
        #expect(ids == [
            GroupRowID.headerID(tagName: "alpha"),
            GroupRowID.fileID(tagName: "alpha", path: "/z.md"),
            GroupRowID.fileID(tagName: "alpha", path: "/a.md"),
        ])
    }

    @Test("an expanded group with no cached members emits only its header")
    func expandedEmptyGroup() {
        let ids = GroupRowOrder.ids(
            tagNames: ["empty"],
            expandedGroups: ["empty"],
            groupFilePaths: ["empty": []])
        #expect(ids == [GroupRowID.headerID(tagName: "empty")])
    }

    @Test("a collapsed group skips its files while a later expanded group still emits them")
    func mixedExpandedAndCollapsed() {
        let ids = GroupRowOrder.ids(
            tagNames: ["alpha", "beta"],
            expandedGroups: ["beta"],
            groupFilePaths: ["alpha": ["/a.md"], "beta": ["/b.md"]])
        #expect(ids == [
            GroupRowID.headerID(tagName: "alpha"),
            GroupRowID.headerID(tagName: "beta"),
            GroupRowID.fileID(tagName: "beta", path: "/b.md"),
        ])
    }

    @Test("an expanded tag missing from the cache emits only its header")
    func expandedTagMissingFromCache() {
        let ids = GroupRowOrder.ids(
            tagNames: ["ghost"],
            expandedGroups: ["ghost"],
            groupFilePaths: [:])
        #expect(ids == [GroupRowID.headerID(tagName: "ghost")])
    }
}
