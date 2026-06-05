import Testing
@testable import DocumentKit

@Suite struct GroupSortTests {

    @Test func sortsByEffectiveDisplayNameCaseInsensitively() {
        let paths = ["/x/Zebra.md", "/x/apple.md", "/x/Mango.md"]
        let sorted = GroupSort.sorted(paths) { _ in nil }   // no overrides → filename
        #expect(sorted == ["/x/apple.md", "/x/Mango.md", "/x/Zebra.md"])
    }

    @Test func displayNameOverrideWins() {
        // Two .env files; their overrides drive the order, not the filename.
        let paths = ["/a/.env", "/b/.env"]
        let names = ["/a/.env": "Zeta keys", "/b/.env": "Alpha keys"]
        let sorted = GroupSort.sorted(paths) { names[$0] }
        #expect(sorted == ["/b/.env", "/a/.env"])   // Alpha before Zeta
    }

    @Test func tieBreaksByFullPathWhenNamesEqual() {
        // Identical effective names → deterministic order by path.
        let paths = ["/z/readme.md", "/a/readme.md"]
        let sorted = GroupSort.sorted(paths) { _ in nil }
        #expect(sorted == ["/a/readme.md", "/z/readme.md"])
    }

    @Test func emptyInputIsEmpty() {
        #expect(GroupSort.sorted([]) { _ in nil } == [])
    }
}
