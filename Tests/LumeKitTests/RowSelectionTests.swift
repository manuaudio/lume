import Testing
@testable import LumeKit

@Suite struct RowSelectionTests {
    let order = ["a", "b", "c", "d", "e"]

    @Test func moveDownReplacesSelection() {
        let r = RowSelection.move(from: "b", in: order, by: 1)
        #expect(r?.selection == ["c"])
        #expect(r?.anchor == "c")
    }

    @Test func moveUpReplacesSelection() {
        let r = RowSelection.move(from: "c", in: order, by: -1)
        #expect(r?.selection == ["b"])
        #expect(r?.anchor == "b")
    }

    @Test func moveStopsAtBottom() {
        #expect(RowSelection.move(from: "e", in: order, by: 1) == nil)
    }

    @Test func moveStopsAtTop() {
        #expect(RowSelection.move(from: "a", in: order, by: -1) == nil)
    }

    @Test func moveWithNoFocusLandsOnFirstGoingDown() {
        let r = RowSelection.move(from: nil, in: order, by: 1)
        #expect(r?.selection == ["a"])
    }

    @Test func moveWithNoFocusLandsOnLastGoingUp() {
        let r = RowSelection.move(from: nil, in: order, by: -1)
        #expect(r?.selection == ["e"])
    }

    @Test func extendDownGrowsContiguousRange() {
        let r = RowSelection.extend(anchor: "b", focus: "b", in: order, by: 1)
        #expect(r?.selection == ["b", "c"])
        #expect(r?.focus == "c")
    }

    @Test func extendDownTwiceFromMovingFocus() {
        let first = RowSelection.extend(anchor: "b", focus: "b", in: order, by: 1)!
        let second = RowSelection.extend(anchor: "b", focus: first.focus, in: order, by: 1)!
        #expect(second.selection == ["b", "c", "d"])
        #expect(second.focus == "d")
    }

    @Test func extendUpAcrossAnchorShrinksThenFlips() {
        // anchor c, focus currently e → extend up moves focus to d; range c…d
        let r = RowSelection.extend(anchor: "c", focus: "e", in: order, by: -1)
        #expect(r?.selection == ["c", "d"])
        #expect(r?.focus == "d")
    }

    @Test func extendStopsAtBottomEdge() {
        #expect(RowSelection.extend(anchor: "d", focus: "e", in: order, by: 1) == nil)
    }

    @Test func selectAllReturnsEverything() {
        #expect(RowSelection.all(in: order) == ["a", "b", "c", "d", "e"])
    }

    @Test func emptyOrderIsSafe() {
        #expect(RowSelection.move(from: nil, in: [], by: 1) == nil)
        #expect(RowSelection.all(in: []) == [])
    }

    // MARK: Stale-id robustness (reviewer-noted gaps)

    @Test func moveFromStaleCurrentLandsOnEdge() {
        // `current` not present in `order` (e.g. the selected row was filtered
        // out): treat it like "no focus" and land on the edge in the move
        // direction — down → first, up → last.
        let down = RowSelection.move(from: "zzz", in: order, by: 1)
        #expect(down?.selection == ["a"])
        #expect(down?.anchor == "a")

        let up = RowSelection.move(from: "zzz", in: order, by: -1)
        #expect(up?.selection == ["e"])
        #expect(up?.anchor == "e")
    }

    @Test func extendWithAbsentAnchorIsNoOp() {
        #expect(RowSelection.extend(anchor: "zzz", focus: "b", in: order, by: 1) == nil)
    }

    @Test func extendWithAbsentFocusIsNoOp() {
        #expect(RowSelection.extend(anchor: "b", focus: "zzz", in: order, by: 1) == nil)
    }

    // MARK: Extend after ⌘A (select-all then ⇧-arrow)

    @Test func extendAfterSelectAllFromSoleAnchorContracts() {
        // ⌘A with a prior sole selection at "b" → anchor "b", focus last "e".
        // ⇧↑ moves focus up to "d"; the range becomes b…d (the rows between the
        // anchor and the new focus), i.e. select-all then ⇧↑ contracts from the
        // bottom toward the anchor — Finder behavior.
        #expect(RowSelection.all(in: order) == ["a", "b", "c", "d", "e"])
        let r = RowSelection.extend(anchor: "b", focus: "e", in: order, by: -1)
        #expect(r?.selection == ["b", "c", "d"])
        #expect(r?.focus == "d")
    }

    @Test func extendAfterSelectAllNoPriorSelectionFromFirst() {
        // ⌘A with no prior sole selection → anchor first "a", focus last "e".
        // ⇧↑ contracts the bottom: range a…d.
        let r = RowSelection.extend(anchor: "a", focus: "e", in: order, by: -1)
        #expect(r?.selection == ["a", "b", "c", "d"])
        #expect(r?.focus == "d")
    }

    // MARK: contiguousRunEndpoints (mouse ⇧-click → keyboard recovery)

    @Test func contiguousRunEndpointsReturnsLowAndHigh() {
        let ep = RowSelection.contiguousRunEndpoints(of: ["b", "c", "d"], in: order)
        #expect(ep?.low == "b")
        #expect(ep?.high == "d")
    }

    @Test func contiguousRunEndpointsSingleRow() {
        let ep = RowSelection.contiguousRunEndpoints(of: ["c"], in: order)
        #expect(ep?.low == "c")
        #expect(ep?.high == "c")
    }

    @Test func contiguousRunEndpointsRejectsGap() {
        // {a, c} is non-contiguous (b missing) → nil.
        #expect(RowSelection.contiguousRunEndpoints(of: ["a", "c"], in: order) == nil)
    }

    @Test func contiguousRunEndpointsRejectsAbsentID() {
        #expect(RowSelection.contiguousRunEndpoints(of: ["b", "zzz"], in: order) == nil)
    }

    @Test func contiguousRunEndpointsEmptyIsNil() {
        #expect(RowSelection.contiguousRunEndpoints(of: [], in: order) == nil)
    }

    @Test func contiguousRunEndpointsIgnoresSetOrdering() {
        // Set has no order; endpoints must come from `order`, not insertion.
        let ep = RowSelection.contiguousRunEndpoints(of: ["d", "b", "c"], in: order)
        #expect(ep?.low == "b")
        #expect(ep?.high == "d")
    }

    // MARK: revalidate (tag filter hides the open file)

    // Ids are "section|d-or-f|path", matching SidebarRow.id.
    private static let fileA = "browser|f|/x/a.md"
    private static let fileB = "browser|f|/x/b.md"
    private static let dir = "browser|d|/x/sub"

    @Test func revalidateNilAllowedPassesThrough() {
        // No active filter ⇒ nothing is cleared.
        let r = RowSelection.revalidate(selection: [Self.fileA, Self.fileB],
                                        anchor: Self.fileA, focus: Self.fileB,
                                        allowed: nil)
        #expect(r.selection == [Self.fileA, Self.fileB])
        #expect(r.anchor == Self.fileA)
        #expect(r.focus == Self.fileB)
    }

    @Test func revalidateDropsDisallowedFile() {
        // Only a.md is allowed; b.md falls out of the selection.
        let r = RowSelection.revalidate(selection: [Self.fileA, Self.fileB],
                                        anchor: Self.fileB, focus: Self.fileB,
                                        allowed: ["/x/a.md"])
        #expect(r.selection == [Self.fileA])
        #expect(r.anchor == nil)   // anchor pointed at dropped row
        #expect(r.focus == nil)    // focus pointed at dropped row
    }

    @Test func revalidateKeepsDirectoriesRegardlessOfAllowed() {
        // A directory row survives even though its path isn't in `allowed`.
        let r = RowSelection.revalidate(selection: [Self.dir, Self.fileB],
                                        anchor: Self.dir, focus: Self.fileB,
                                        allowed: ["/x/a.md"])
        #expect(r.selection == [Self.dir])
        #expect(r.anchor == Self.dir)  // directory anchor preserved
        #expect(r.focus == nil)        // file focus dropped
    }

    @Test func revalidateKeepsUndecodableIdsFailOpen() {
        // An id that doesn't split into 3 parts is kept rather than silently lost.
        let r = RowSelection.revalidate(selection: ["weird-id", Self.fileA],
                                        anchor: nil, focus: nil,
                                        allowed: Set<String>())
        #expect(r.selection == ["weird-id"])
    }

    @Test func revalidatePathWithPipeDecodesCorrectly() {
        // Paths may contain "|"; only the first two separators are structural.
        let id = "browser|f|/x/a|b.md"
        let r = RowSelection.revalidate(selection: [id], anchor: id, focus: id,
                                        allowed: ["/x/a|b.md"])
        #expect(r.selection == [id])
        #expect(r.anchor == id)
        #expect(r.focus == id)
    }

    // MARK: click (mouse single-click — the regression these guard)

    @Test func plainClickSoleSelectsAndAnchors() {
        // A plain click collapses any prior selection to just the clicked row,
        // which becomes the new anchor/focus. (The caller then activates it.)
        let r = RowSelection.click(target: "c", current: ["a", "b"], anchor: "a",
                                   in: order, command: false, shift: false)
        #expect(r.selection == ["c"])
        #expect(r.anchor == "c")
        #expect(r.focus == "c")
    }

    @Test func plainClickWithNoPriorSelectionSelectsRow() {
        let r = RowSelection.click(target: "b", current: [], anchor: nil,
                                   in: order, command: false, shift: false)
        #expect(r.selection == ["b"])
        #expect(r.anchor == "b")
    }

    @Test func commandClickAddsToSelectionAndMovesAnchor() {
        let r = RowSelection.click(target: "d", current: ["a", "b"], anchor: "a",
                                   in: order, command: true, shift: false)
        #expect(r.selection == ["a", "b", "d"])
        #expect(r.anchor == "d")
        #expect(r.focus == "d")
    }

    @Test func commandClickOnSelectedRowRemovesIt() {
        let r = RowSelection.click(target: "b", current: ["a", "b", "c"], anchor: "a",
                                   in: order, command: true, shift: false)
        #expect(r.selection == ["a", "c"])
        #expect(r.anchor == "a")   // anchor was elsewhere → preserved
    }

    @Test func commandClickRemovingTheAnchorClearsAnchor() {
        let r = RowSelection.click(target: "a", current: ["a", "b"], anchor: "a",
                                   in: order, command: true, shift: false)
        #expect(r.selection == ["b"])
        #expect(r.anchor == nil)   // removed the anchor itself
        #expect(r.focus == nil)
    }

    @Test func shiftClickSelectsContiguousRangeFromAnchor() {
        let r = RowSelection.click(target: "d", current: ["b"], anchor: "b",
                                   in: order, command: false, shift: true)
        #expect(r.selection == ["b", "c", "d"])
        #expect(r.anchor == "b")   // anchor stays put
        #expect(r.focus == "d")
    }

    @Test func shiftClickRangeWorksUpwardToo() {
        let r = RowSelection.click(target: "a", current: ["c"], anchor: "c",
                                   in: order, command: false, shift: true)
        #expect(r.selection == ["a", "b", "c"])
        #expect(r.anchor == "c")
        #expect(r.focus == "a")
    }

    @Test func shiftClickWithoutAnchorFallsBackToPlain() {
        let r = RowSelection.click(target: "d", current: ["b"], anchor: nil,
                                   in: order, command: false, shift: true)
        #expect(r.selection == ["d"])
        #expect(r.anchor == "d")
    }

    @Test func commandTakesPrecedenceOverShift() {
        // If both modifiers are reported, ⌘ (toggle) wins — never silently range.
        let r = RowSelection.click(target: "c", current: ["c"], anchor: "a",
                                   in: order, command: true, shift: true)
        #expect(r.selection == [])   // toggled the only selected row off
    }
}
