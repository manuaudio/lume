import Testing
@testable import LumeKit

/// Pure-logic coverage for `GroupSelection`, the helper that revalidates the
/// sidebar selection (ids + anchor + focus) and the expanded-groups set after a
/// GROUP mutation (delete / rename / remove-from-group). AppModel lives in the
/// app target and isn't unit-testable here, so the id-rewriting math is extracted
/// into this pure helper and the model methods delegate to it.
@Suite struct GroupSelectionTests {

    // Convenience id builders.
    private func header(_ name: String) -> String { GroupRowID.headerID(tagName: name) }
    private func file(_ name: String, _ path: String) -> String {
        GroupRowID.fileID(tagName: name, path: path)
    }

    // MARK: Delete

    @Test func deleteDropsMatchingHeaderAndFileIDs() {
        let selection: Set<String> = [
            header("alpha"), file("alpha", "/x/a.md"), file("alpha", "/x/b.md"),
            header("beta"), file("beta", "/x/c.md"),       // unrelated → survive
            "browser|f|/x/keep.md",                         // non-group → survive
        ]
        let r = GroupSelection.afterDelete(name: "alpha",
                                           selection: selection,
                                           anchor: header("alpha"),
                                           focus: file("alpha", "/x/a.md"),
                                           expandedGroups: ["alpha", "beta"])
        #expect(r.selection == [header("beta"), file("beta", "/x/c.md"), "browser|f|/x/keep.md"])
        // Anchor + focus both decoded to alpha → nilled.
        #expect(r.anchor == nil)
        #expect(r.focus == nil)
        // alpha pruned from the expanded set, beta untouched.
        #expect(r.expandedGroups == ["beta"])
    }

    @Test func deleteKeepsUnrelatedAnchorFocus() {
        let r = GroupSelection.afterDelete(name: "alpha",
                                           selection: [header("beta")],
                                           anchor: header("beta"),
                                           focus: "browser|f|/x/k.md",
                                           expandedGroups: ["beta"])
        #expect(r.anchor == header("beta"))
        #expect(r.focus == "browser|f|/x/k.md")
        #expect(r.expandedGroups == ["beta"])
    }

    // MARK: Rename

    @Test func renameRewritesIDsAnchorFocusAndExpanded() {
        let selection: Set<String> = [
            header("old"), file("old", "/x/a.md"),
            header("keep"), "browser|f|/x/z.md",
        ]
        let r = GroupSelection.afterRename(old: "old", new: "new",
                                           selection: selection,
                                           anchor: file("old", "/x/a.md"),
                                           focus: header("old"),
                                           expandedGroups: ["old", "keep"])
        // old→new ids rewritten, path preserved; unrelated ids untouched.
        #expect(r.selection == [
            header("new"), file("new", "/x/a.md"),
            header("keep"), "browser|f|/x/z.md",
        ])
        #expect(r.anchor == file("new", "/x/a.md"))
        #expect(r.focus == header("new"))
        // expandedGroups migrated old→new, keep retained.
        #expect(r.expandedGroups == ["new", "keep"])
    }

    @Test func renameOntoExistingGroupCollapsesDuplicatesHarmlessly() {
        // Merge case: "old" renamed to "new" which already had the same file.
        let selection: Set<String> = [file("old", "/x/a.md"), file("new", "/x/a.md")]
        let r = GroupSelection.afterRename(old: "old", new: "new",
                                           selection: selection,
                                           anchor: nil, focus: nil,
                                           expandedGroups: ["old", "new"])
        #expect(r.selection == [file("new", "/x/a.md")])
        #expect(r.expandedGroups == ["new"])
    }

    @Test func renameWhenOldNotExpandedDoesNotInsertNew() {
        let r = GroupSelection.afterRename(old: "old", new: "new",
                                           selection: [],
                                           anchor: nil, focus: nil,
                                           expandedGroups: ["keep"])
        #expect(r.expandedGroups == ["keep"])
    }

    // MARK: Remove-from-group

    @Test func removeDropsExactlyTheOneID() {
        let target = file("alpha", "/x/a.md")
        let selection: Set<String> = [
            target,
            file("alpha", "/x/b.md"),   // same group, different file → survive
            file("beta", "/x/a.md"),    // same file, different group → survive
            header("alpha"),
        ]
        let r = GroupSelection.afterRemove(path: "/x/a.md", name: "alpha",
                                           selection: selection,
                                           anchor: target,
                                           focus: target)
        #expect(r.selection == [file("alpha", "/x/b.md"), file("beta", "/x/a.md"), header("alpha")])
        #expect(r.anchor == nil)
        #expect(r.focus == nil)
    }

    @Test func removeKeepsUnrelatedAnchorFocus() {
        let r = GroupSelection.afterRemove(path: "/x/a.md", name: "alpha",
                                           selection: [header("alpha")],
                                           anchor: header("alpha"),
                                           focus: header("alpha"))
        #expect(r.anchor == header("alpha"))
        #expect(r.focus == header("alpha"))
    }
}
