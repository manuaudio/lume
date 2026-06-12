import Foundation
import Observation
import LumeKit

/// GitHub backend lifecycle: gh auth check, repo metadata (default branch +
/// push permission), branch list. The active branch is session state here —
/// the `RemoteSession` above stays branch-agnostic.
@MainActor
@Observable
final class GitHubConnection: RemoteConnection {
    let ref: GitHubRepoRef
    let client: GitHubClient
    let source: GitHubFileSource
    private let preferredBranch: String?
    private let startPath: String?

    /// Branch names fetched on connect (capped at 100 — see GitHubClient).
    private(set) var branches: [String] = []
    private(set) var activeBranch: String?
    /// False → the header shows a read-only badge; saves would 403.
    private(set) var canPush = true

    init(ref: GitHubRepoRef, client: GitHubClient,
         preferredBranch: String?, startPath: String?) {
        self.ref = ref
        self.client = client
        self.source = GitHubFileSource(slug: ref.slug, client: client)
        self.preferredBranch = preferredBranch
        self.startPath = startPath
    }

    var sourceID: SourceID { .github(slug: ref.slug) }
    var displayName: String { ref.slug }

    func connect() async throws -> String {
        try await client.checkAuth()
        let info = try await client.repoInfo(slug: ref.slug)
        canPush = info.canPush
        // Branch list is best-effort: a failure here shouldn't block browsing.
        branches = (try? await client.listBranches(slug: ref.slug)) ?? [info.defaultBranch]
        let branch = preferredBranch.flatMap { branches.contains($0) ? $0 : nil }
            ?? info.defaultBranch
        activeBranch = branch
        await source.setBranch(branch)
        return startPath ?? "/"
    }

    /// Branch switch: drops the source's sha cache (old-branch blobs).
    func setActiveBranch(_ branch: String) async {
        activeBranch = branch
        await source.setBranch(branch)
    }

    func disconnect() async {
        // Nothing persistent to tear down — gh calls are one-shot.
    }

    func userMessage(for error: Error) -> String {
        (error as? GitHubError)?.userMessage ?? error.localizedDescription
    }
}
