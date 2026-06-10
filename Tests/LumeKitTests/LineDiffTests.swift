import Testing
@testable import LumeKit

@Test func identicalTextsAllSame() {
    let d = LineDiff.compute(from: "a\nb\nc", to: "a\nb\nc")
    #expect(d.allSatisfy { $0.kind == .same })
    #expect(d.map(\.text) == ["a", "b", "c"])
}

@Test func addedLine() {
    let d = LineDiff.compute(from: "a\nc", to: "a\nb\nc")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .added, text: "b"),
        DiffLine(kind: .same, text: "c"),
    ])
}

@Test func removedLine() {
    let d = LineDiff.compute(from: "a\nb\nc", to: "a\nc")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: "b"),
        DiffLine(kind: .same, text: "c"),
    ])
}

@Test func changedLineIsRemoveThenAdd() {
    let d = LineDiff.compute(from: "a\nB\nc", to: "a\nX\nc")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: "B"),
        DiffLine(kind: .added, text: "X"),
        DiffLine(kind: .same, text: "c"),
    ])
}

@Test func emptyToOneLineReplacesEmptyLine() {
    let d = LineDiff.compute(from: "", to: "hello")
    #expect(d == [DiffLine(kind: .removed, text: ""), DiffLine(kind: .added, text: "hello")])
}

// MARK: - Edge cases (audit gap-fill)
// These pin the CURRENT contract of `components(separatedBy: "\n")`: a trailing
// newline yields a final "" line, and "" itself is ONE empty line, never zero.
// Newline-presence changes are therefore visible as an added/removed blank row.

@Test func bothEmptyIsOneSameEmptyLine() {
    let d = LineDiff.compute(from: "", to: "")
    #expect(d == [DiffLine(kind: .same, text: "")])
}

@Test func addingTrailingNewlineShowsAddedEmptyLine() {
    let d = LineDiff.compute(from: "a\nb", to: "a\nb\n")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .same, text: "b"),
        DiffLine(kind: .added, text: ""),
    ])
}

@Test func removingTrailingNewlineShowsRemovedEmptyLine() {
    let d = LineDiff.compute(from: "a\n", to: "a")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: ""),
    ])
}

@Test func identicalTextsWithTrailingNewlineKeepEmptyLastLine() {
    let d = LineDiff.compute(from: "a\n", to: "a\n")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .same, text: ""),
    ])
}

@Test func multiHunkChangesInterleaveInDocumentOrder() {
    // Two separated hunks (line 2 and line 5 change) must come out interleaved
    // with the unchanged middle, each as remove-then-add at its own position.
    let d = LineDiff.compute(from: "a\nb\nc\nd\ne", to: "a\nX\nc\nd\nY")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: "b"),
        DiffLine(kind: .added, text: "X"),
        DiffLine(kind: .same, text: "c"),
        DiffLine(kind: .same, text: "d"),
        DiffLine(kind: .removed, text: "e"),
        DiffLine(kind: .added, text: "Y"),
    ])
}

@Test func emptyOldToMultilineNewReplacesTheEmptyLine() {
    let d = LineDiff.compute(from: "", to: "a\nb")
    #expect(d == [
        DiffLine(kind: .removed, text: ""),
        DiffLine(kind: .added, text: "a"),
        DiffLine(kind: .added, text: "b"),
    ])
}
