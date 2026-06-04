import Testing
@testable import LumeCore

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
}
