import Testing
@testable import LumeKit

struct GitHubRepoRefTests {
    @Test func parsesBareSlug() {
        let ref = GitHubRepoRef(parsing: "manuaudio/lume")
        #expect(ref?.owner == "manuaudio")
        #expect(ref?.name == "lume")
        #expect(ref?.slug == "manuaudio/lume")
    }

    @Test func parsesURLVariants() {
        for input in [
            "https://github.com/manuaudio/lume",
            "https://github.com/manuaudio/lume.git",
            "https://github.com/manuaudio/lume/tree/main/docs",
            "https://github.com/manuaudio/lume/blob/main/README.md",
            "github.com/manuaudio/lume/",
            "git@github.com:manuaudio/lume.git",
        ] {
            #expect(GitHubRepoRef(parsing: input)?.slug == "manuaudio/lume", "failed: \(input)")
        }
    }

    @Test func trimsWhitespace() {
        #expect(GitHubRepoRef(parsing: "  owner/repo \n")?.slug == "owner/repo")
    }

    @Test func rejectsJunk() {
        for input in ["", "lume", "a/b/c", "owner/", "/repo", "owner/re po", "owner/re|po"] {
            #expect(GitHubRepoRef(parsing: input) == nil, "should reject: \(input)")
        }
    }

    @Test func githubSourceIDsDistinguishRepos() {
        #expect(SourceID.github(slug: "a/x") != SourceID.github(slug: "a/y"))
        #expect(SourceID.github(slug: "a/x") != SourceID.ssh(alias: "a/x"))
    }
}
