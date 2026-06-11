import Testing
import Foundation
@testable import LumeKit

struct GitHubErrorTests {
    private func map(stdout: String = "", stderr: String = "", path: String? = nil) -> GitHubError {
        GitHubError.map(exitCode: 1, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), path: path)
    }

    @Test func notAuthenticated() {
        #expect(map(stderr: "To get started with GitHub CLI, please run:  gh auth login")
                == .notAuthenticated)
        #expect(map(stderr: "You are not logged into any GitHub hosts.") == .notAuthenticated)
    }

    @Test func rateLimitBeforeGenericForbidden() {
        // Rate-limit responses are HTTP 403 too — must classify before 403.
        #expect(map(stderr: "gh: API rate limit exceeded for user (HTTP 403)") == .rateLimited)
    }

    @Test func repoVsFileNotFound() {
        #expect(map(stderr: "gh: Not Found (HTTP 404)") == .repoNotFound)
        #expect(map(stderr: "gh: Not Found (HTTP 404)", path: "/docs/gone.md")
                == .notFound(path: "/docs/gone.md"))
    }

    @Test func branchNotFound() {
        #expect(map(stdout: #"{"message":"No commit found for the ref nope"}"#,
                    stderr: "gh: No commit found for the ref nope (HTTP 404)",
                    path: "/a.md") == .branchNotFound)
    }

    @Test func writeConflictFrom409And422() {
        #expect(map(stderr: #"gh: docs/a.md does not match (HTTP 409)"#, path: "/docs/a.md")
                == .writeConflict(path: "/docs/a.md"))
        #expect(map(stderr: #"gh: "sha" wasn't supplied. (HTTP 422)"#, path: "/docs/a.md")
                == .writeConflict(path: "/docs/a.md"))
    }

    @Test func permissionDenied() {
        #expect(map(stderr: "gh: Resource not accessible by integration (HTTP 403)", path: "/x")
                == .permissionDenied(path: "/x"))
    }

    @Test func networkFailures() {
        #expect(map(stderr: "dial tcp: lookup api.github.com: no such host")
                == .network(detail: "dial tcp: lookup api.github.com: no such host"))
    }

    @Test func unknownFallsBackToProtocolFailure() {
        #expect(map(stderr: "something nobody expected")
                == .protocolFailure(detail: "something nobody expected"))
        #expect(map() == .protocolFailure(detail: "exit code 1"))
    }

    @Test func messagesAreHuman() {
        #expect(GitHubError.writeConflict(path: "/docs/a.md").userMessage
                == "a.md changed on GitHub since you opened it.")
        #expect(GitHubError.notAuthenticated.userMessage.contains("gh auth login"))
        #expect(GitHubError.ghNotInstalled.userMessage.contains("brew install gh"))
    }
}
