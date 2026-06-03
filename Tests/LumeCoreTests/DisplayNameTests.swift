import Testing
import Foundation
@testable import LumeCore

// MARK: isAmbiguous

@Test func displayName_isAmbiguousMatchesCuratedExactNames() {
    for n in ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "README.md",
              "index.html", "index.md", "package.json", "Dockerfile",
              "docker-compose.yml", "Makefile", ".gitignore"] {
        #expect(DisplayName.isAmbiguous(n), "\(n) should be ambiguous")
    }
}

@Test func displayName_isAmbiguousIsCaseInsensitive() {
    #expect(DisplayName.isAmbiguous("claude.md"))
    #expect(DisplayName.isAmbiguous("ReadMe.MD"))
    #expect(DisplayName.isAmbiguous("DOCKERFILE"))
}

@Test func displayName_isAmbiguousMatchesEnvAndEnvVariants() {
    #expect(DisplayName.isAmbiguous(".env"))
    #expect(DisplayName.isAmbiguous(".env.local"))
    #expect(DisplayName.isAmbiguous(".env.production"))
    #expect(DisplayName.isAmbiguous(".ENV"))
}

@Test func displayName_isAmbiguousRejectsNonMatches() {
    #expect(!DisplayName.isAmbiguous("notes.md"))
    #expect(!DisplayName.isAmbiguous("main.swift"))
    #expect(!DisplayName.isAmbiguous("environment"))   // no leading dot
    #expect(!DisplayName.isAmbiguous(".environment"))  // ".env." prefix requires the trailing dot
    #expect(!DisplayName.isAmbiguous("README.txt"))
}

// MARK: autoName

@Test func displayName_autoNameReturnsParentFolderForAmbiguousFile() {
    let url = URL(fileURLWithPath: "/Users/me/freshydeli/.env")
    #expect(DisplayName.autoName(for: url) == "freshydeli")
}

@Test func displayName_autoNameWorksForEnvVariantAndDeepPath() {
    let url = URL(fileURLWithPath: "/Users/me/projects/cara/.env.local")
    #expect(DisplayName.autoName(for: url) == "cara")
}

@Test func displayName_autoNameIsNilForNonAmbiguousFile() {
    let url = URL(fileURLWithPath: "/Users/me/freshydeli/notes.md")
    #expect(DisplayName.autoName(for: url) == nil)
}

@Test func displayName_autoNameAtFilesystemRootReturnsRoot() {
    // Edge: ambiguous file directly at "/" — parent is "/", documents the behavior.
    #expect(DisplayName.autoName(for: URL(fileURLWithPath: "/CLAUDE.md")) == "/")
}
