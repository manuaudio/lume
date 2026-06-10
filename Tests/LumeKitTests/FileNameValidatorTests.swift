import Testing
@testable import LumeKit

@Test func acceptsOrdinaryNames() {
    #expect(FileNameValidator.isValid("notes.md"))
    #expect(FileNameValidator.isValid(".env"))
    #expect(FileNameValidator.isValid("a b c"))
    #expect(FileNameValidator.isValid("notes..md"))   // ".." inside a name is harmless without "/"
}

@Test func rejectsPathSeparatorsAndTraversal() {
    #expect(!FileNameValidator.isValid("a/b"))
    #expect(!FileNameValidator.isValid("../escape"))
    #expect(!FileNameValidator.isValid("/abs"))
    #expect(!FileNameValidator.isValid(".."))
    #expect(!FileNameValidator.isValid("."))
    #expect(!FileNameValidator.isValid(""))
    #expect(!FileNameValidator.isValid("nul\0name"))
}
