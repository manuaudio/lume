import Testing
@testable import LibraryKit

/// Wrapped in an explicit `@Suite struct` so `swift test --filter TagSuggestTests`
/// matches the SUITE by name. Free `@Test` functions only expose their own symbol
/// names to `--filter`, so a `--filter TagSuggestTests` against free functions can
/// silently match zero tests and pass vacuously (false green). The suite name gives
/// the gate a stable, non-empty target.
@Suite struct TagSuggestTests {

    @Test func emptyQueryReturnsAllSortedExcludingExisting() {
        let out = TagSuggest.suggestions(
            query: "",
            allNames: ["zebra", "apple", "work"],
            existingOnFile: ["work"]
        )
        #expect(out == ["apple", "zebra"])   // sorted, "work" excluded (already on file)
    }

    @Test func prefixFilterIsCaseInsensitive() {
        let out = TagSuggest.suggestions(
            query: "Wo",
            allNames: ["work", "world", "home"],
            existingOnFile: []
        )
        #expect(out == ["work", "world"])
    }

    @Test func draftIsTrimmedBeforeMatching() {
        let out = TagSuggest.suggestions(
            query: "  wo  ",
            allNames: ["work", "home"],
            existingOnFile: []
        )
        #expect(out == ["work"])
    }

    @Test func suggestionsAreDedupedAndExcludeFileTags() {
        let out = TagSuggest.suggestions(
            query: "a",
            allNames: ["alpha", "alpha", "apple", "beta"],
            existingOnFile: ["apple"]
        )
        #expect(out == ["alpha"])   // deduped; "apple" excluded; "beta" filtered out by prefix
    }

    @Test func emptyQuerySortsCaseInsensitively() {
        let out = TagSuggest.suggestions(
            query: "",
            allNames: ["Banana", "apple"],
            existingOnFile: []
        )
        #expect(out == ["apple", "Banana"])   // lowercased-ascending order, original casing preserved
    }

    @Test func shouldOfferCreateWhenDraftIsNovel() {
        #expect(TagSuggest.shouldOfferCreate(query: "fresh", allNames: ["work"], existingOnFile: []) == true)
    }

    @Test func shouldNotOfferCreateForBlankOrExisting() {
        #expect(TagSuggest.shouldOfferCreate(query: "   ", allNames: [], existingOnFile: []) == false)
        #expect(TagSuggest.shouldOfferCreate(query: "Work", allNames: ["work"], existingOnFile: []) == false) // case-insensitive existing
        #expect(TagSuggest.shouldOfferCreate(query: "done", allNames: [], existingOnFile: ["done"]) == false) // already on file
    }
}
