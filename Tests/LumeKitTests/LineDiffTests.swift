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
