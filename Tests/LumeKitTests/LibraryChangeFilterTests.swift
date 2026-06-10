import Testing
@testable import LumeKit

@Test func untrackedChurnDoesNotAffectLibrary() {
    #expect(!LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/src/main.swift", "/repo/src"],
        favoritePaths: ["/repo/CLAUDE.md"],
        hiddenPaths: ["/repo/secret.md"],
        groupFilePaths: ["docs": ["/repo/README.md"]]
    ))
}

@Test func favoriteChangeAffectsLibrary() {
    #expect(LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/CLAUDE.md"],
        favoritePaths: ["/repo/CLAUDE.md"],
        hiddenPaths: [],
        groupFilePaths: [:]
    ))
}

@Test func hiddenPathChangeAffectsLibrary() {
    #expect(LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/secret.md"],
        favoritePaths: [],
        hiddenPaths: ["/repo/secret.md"],
        groupFilePaths: [:]
    ))
}

@Test func groupMemberChangeAffectsLibrary() {
    #expect(LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/README.md"],
        favoritePaths: [],
        hiddenPaths: [],
        groupFilePaths: ["docs": ["/repo/README.md"], "empty": []]
    ))
}

@Test func emptyChangeSetIsFalse() {
    #expect(!LibraryChangeFilter.affectsLibrary(
        changed: [],
        favoritePaths: ["/a"],
        hiddenPaths: ["/b"],
        groupFilePaths: ["g": ["/c"]]
    ))
}
