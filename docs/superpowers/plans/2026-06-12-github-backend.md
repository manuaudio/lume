# GitHub Repo Editing Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a GitHub repository in Lume's sidebar, browse it, and make quick edits that commit directly to a chosen branch on ⌘S — same look and feel as the SSH remote experience.

**Architecture:** First, pay the unification debt the SSH plan deferred: a `RemoteConnection` lifecycle protocol + `RemoteSession` generalized over `any FileSource` (tree state is already source-agnostic), with `SSHConnection` extracted from today's SSH-typed session. Then a LumeKit `GitHub/` layer mirrors the SSH stack: `GitHubClient` shells out to the `gh` CLI through the existing `CommandRunning` seam, `GitHubFileSource` (actor) implements `FileSource` with a per-path blob-sha cache (the optimistic-concurrency token for conflict-safe writes), and `GitHubConnection` handles auth check + repo metadata + branch state. UI reuses the remote tree/switcher/save plumbing with a branch chip, two repo-picking sheets, and a conflict-reload dialog.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, Swift Testing (`import Testing`, `#expect`), XcodeGen, system `gh` CLI. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-06-11-github-backend-design.md`

**Documented deviations from the spec** (simplifications — flag to the user if they object):
1. `rateLimited` carries no `resetAt` date — gh doesn't surface the reset header in stderr reliably; the message says "try again in a few minutes" instead.
2. Two error cases beyond the spec's table: `notFound(path:)` (file-level 404, e.g. file deleted remotely mid-session) and `notUTF8(path:)` (binary file → routes to the existing "Can't Open" pane, same as SSH).
3. Branch list capped at one page of 100 (`per_page=100`, no `--paginate`); repo browser capped at 200 (`gh repo list --limit 200`). Both are commented in code.
4. Task 1 (the remote-layer generalization) has no new unit tests — `RemoteSession`/`AppState` live in the app target, which has no test bundle (same as the SSH MVP's UI tasks). The full existing LumeKit suite + a clean build are the regression net.
5. *(post-implementation)* `branchNotFound` mid-session shows the error notice only — the spec's "branch menu refreshes; fall back to default branch" exists at connect time, not mid-session. A rate-limited listing renders an empty directory + notice rather than the spec's "tree unchanged" (the pre-existing SSH listing-error pattern).

**Build/test commands** (used throughout; run from repo root):

```bash
# After ANY task that creates a new .swift file, regenerate the project first:
xcodegen generate

# Run one test suite:
xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:'LumeKitTests/<SuiteName>' 2>&1 | tail -20

# Full build + all tests:
xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' \
  -derivedDataPath build 2>&1 | tail -20
```

---

### Task 1: Generalize the remote layer (`RemoteConnection` + `RemoteSession` over `any FileSource`)

Pure refactor — **no visible change**. The existing test suite is the net.

**Files:**
- Create: `Sources/Lume/Remote/RemoteConnection.swift`
- Create: `Sources/Lume/Remote/SSHConnection.swift`
- Modify: `Sources/Lume/Remote/RemoteSession.swift` (drop SSH-typed members)
- Modify: `Sources/Lume/AppState.swift` (remote lifecycle + open/save sections)
- Modify: `Sources/Lume/Remote/RemoteTreeView.swift` (alias → displayName, recents)
- Modify: `Sources/Lume/Remote/SourceSwitcherView.swift` (alias → displayName)

- [ ] **Step 1: Create `Sources/Lume/Remote/RemoteConnection.swift`**

```swift
import Foundation
import LumeKit

/// The per-backend lifecycle behind a `RemoteSession`: SSH and GitHub each
/// implement this; `RemoteSession` owns the source-agnostic tree state above.
@MainActor
protocol RemoteConnection: AnyObject {
    var sourceID: SourceID { get }
    /// What the switcher/header shows ("web1", "owner/repo").
    var displayName: String { get }
    /// Establish the connection; returns the absolute root path to browse.
    func connect() async throws -> String
    /// Tear down (best-effort; no throw).
    func disconnect() async
    /// Human message for an error thrown by this backend's source/transport.
    func userMessage(for error: Error) -> String
}
```

- [ ] **Step 2: Create `Sources/Lume/Remote/SSHConnection.swift`** (extracted from today's `RemoteSession`)

```swift
import Foundation
import LumeKit

/// SSH backend lifecycle: ControlMaster connect + start-path resolution.
/// Owns the transport and source; `RemoteSession` only sees the protocols.
@MainActor
final class SSHConnection: RemoteConnection {
    let host: SSHHost
    let transport: SSHTransport
    let source: SSHFileSource
    private let startPath: String?

    init(host: SSHHost, startPath: String?) {
        self.host = host
        self.startPath = startPath
        let transport = SSHTransport(host: host)
        self.transport = transport
        self.source = SSHFileSource(host: host, transport: transport)
    }

    var sourceID: SourceID { .ssh(alias: host.alias) }
    var displayName: String { host.alias }

    func connect() async throws -> String {
        try await transport.connect()
        let start = startPath ?? "."
        return start.hasPrefix("/") ? start : try await source.realpath(start)  // "." → home dir
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func userMessage(for error: Error) -> String {
        (error as? SSHError)?.userMessage ?? error.localizedDescription
    }
}
```

- [ ] **Step 3: Rewrite `Sources/Lume/Remote/RemoteSession.swift`**

Replace the whole file (the tree-state members are unchanged; only the SSH-typed trio and `connect()` change):

```swift
import Foundation
import Observation
import LumeKit

/// One live remote session: its backend connection, file source, and the
/// remote tree's UI state (root, expansion, lazily-loaded children).
@MainActor
@Observable
final class RemoteSession {
    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let connection: any RemoteConnection
    let source: any FileSource

    var phase: Phase = .connecting
    /// The directory the tree is rooted at (resolved to absolute on connect).
    var rootPath: String = "/"
    /// Lazily-loaded children per directory path; missing key = not loaded yet.
    private(set) var children: [String: [ResourceNode]] = [:]
    var expanded: Set<String> = []
    /// In-flight loads (guards double-fetch from row `.task` + toggleExpand).
    @ObservationIgnored private var loading: Set<String> = []
    /// Last non-fatal listing error (shown as a notice by the tree view).
    var lastError: String?

    var sourceID: SourceID { connection.sourceID }
    var displayName: String { connection.displayName }

    init(connection: any RemoteConnection, source: any FileSource) {
        self.connection = connection
        self.source = source
    }

    func connect() async {
        phase = .connecting
        do {
            rootPath = try await connection.connect()
            phase = .ready
            await loadChildren(of: rootPath)
        } catch {
            phase = .failed(connection.userMessage(for: error))
        }
    }

    func disconnect() async {
        await connection.disconnect()
    }

    func userMessage(for error: Error) -> String {
        connection.userMessage(for: error)
    }

    func loadChildren(of path: String) async {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            children[path] = try await source.list(path, includeHidden: false)
        } catch {
            children[path] = []
            lastError = connection.userMessage(for: error)
        }
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil {
                Task { await loadChildren(of: path) }
            }
        }
    }

    /// Re-root the tree (go-to-path on a directory).
    func reroot(to path: String) async {
        rootPath = path
        expanded.removeAll()
        children.removeAll()
        await loadChildren(of: path)
    }
}
```

- [ ] **Step 4: Update `Sources/Lume/AppState.swift` — lifecycle methods**

In `connectSSH(_:)`, replace the body:

```swift
    func connectSSH(_ host: SSHHost) {
        // Reconnecting to the already-active host just brings its tree back.
        if let remote, remote.sourceID == .ssh(alias: host.alias) {
            showRemoteSource()
            if case .failed = remote.phase { Task { await remote.connect() } }
            return
        }
        let previous = remote
        Task { await previous?.disconnect() }
        let connection = SSHConnection(
            host: host,
            startPath: connections.state.hostState[host.alias]?.lastPath)
        let session = RemoteSession(connection: connection, source: connection.source)
        remote = session
        showingRemote = true
        clearDocumentSelection()
        connections.noteConnected(alias: host.alias)
        Task { await session.connect() }
    }
```

In `disconnectRemote()`, change the transport teardown line:

```swift
        Task { await session?.disconnect() }
```

- [ ] **Step 5: Update `AppState.swift` — open/save section**

Add two private helpers and one computed property at the end of the `// MARK: - Remote source (SSH) — open / save` section (the `default:` arms are replaced with `.github` cases in Task 7):

```swift
    /// Per-backend store bookkeeping: "user opened this remote file".
    private func noteRemoteOpened(_ path: String) {
        guard let remote else { return }
        switch remote.sourceID {
        case .ssh(let alias): connections.noteOpened(alias: alias, file: path)
        default: break
        }
    }

    /// Per-backend store bookkeeping: "user browsed to this remote directory".
    private func noteRemoteBrowsed(_ path: String) {
        guard let remote else { return }
        switch remote.sourceID {
        case .ssh(let alias): connections.noteBrowsed(alias: alias, path: path)
        default: break
        }
    }

    /// Recent files for the active remote (drives the tree's Recent section).
    var remoteRecentFiles: [String] {
        guard let remote else { return [] }
        switch remote.sourceID {
        case .ssh(let alias): return connections.state.hostState[alias]?.recentFiles ?? []
        default: return []
        }
    }
```

Then replace every SSH-typed expression in `selectRemote`, `goToRemotePath`, and `saveRemote`:

- In `selectRemote`: `connections.noteOpened(alias: remote.host.alias, file: path)` → `noteRemoteOpened(path)`, and the catch's message → `errorMessage = remote.userMessage(for: error)`.
- In `goToRemotePath`: `connections.noteBrowsed(alias: remote.host.alias, path: path)` → `noteRemoteBrowsed(path)`, and the catch → `showNotice(remote.userMessage(for: error))`.
- In `saveRemote`'s catch → `showNotice(remote.userMessage(for: error))`.

- [ ] **Step 6: Update the two views**

`Sources/Lume/Remote/RemoteTreeView.swift`:
- `"Connecting to \(remote.host.alias)…"` → `"Connecting to \(remote.displayName)…"`
- Replace the `recentFiles` computed property:

```swift
    private var recentFiles: [String] { app.remoteRecentFiles }
```

`Sources/Lume/Remote/SourceSwitcherView.swift`:
- Line 21 (`Label(remote.host.alias, …)`) → `Label(remote.displayName, systemImage: "bolt.horizontal")`
- In `title`: `return remote.host.alias` → `return remote.displayName`

- [ ] **Step 7: Build and run the FULL test suite**

Run: `xcodegen generate && xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED, same test count as before (refactor adds none).

- [ ] **Step 8: Commit**

```bash
git add Sources/Lume/Remote/ Sources/Lume/AppState.swift
git commit -m "refactor: generalize RemoteSession over RemoteConnection + any FileSource"
```

---
### Task 2: `SourceID.github` + `GitHubRepoRef`

**Files:**
- Modify: `Sources/LumeKit/ResourceTypes.swift` (add one enum case)
- Create: `Sources/LumeKit/GitHub/GitHubRepoRef.swift`
- Test: `Tests/LumeKitTests/GitHubRepoRefTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test ... -only-testing:'LumeKitTests/GitHubRepoRefTests' 2>&1 | tail -20`
Expected: BUILD FAILS — `cannot find 'GitHubRepoRef' in scope`

- [ ] **Step 3: Add the enum case to `Sources/LumeKit/ResourceTypes.swift`**

```swift
/// Which backend a resource lives in. `.local` is the on-disk workspace;
/// `.ssh` is a connected remote host (keyed by its alias/nickname);
/// `.github` is a GitHub repository (keyed by "owner/repo"; the active
/// branch is session state, not identity).
public enum SourceID: Hashable, Sendable {
    case local
    case ssh(alias: String)
    case github(slug: String)
}
```

- [ ] **Step 4: Create `Sources/LumeKit/GitHub/GitHubRepoRef.swift`**

```swift
import Foundation

/// One GitHub repository, parsed from user input: a bare "owner/repo" slug,
/// a github.com URL (https or ssh, .git suffix, tree/blob deep links), all
/// reduce to the same owner/name pair.
public struct GitHubRepoRef: Hashable, Sendable {
    public let owner: String
    public let name: String

    public var slug: String { "\(owner)/\(name)" }

    public init?(parsing raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let range = s.range(of: "github.com") {
            // URL form: everything after the host, ":" (ssh) or "/" (https).
            s = String(s[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
            let parts = s.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }   // deep links: keep first two
            owner = parts[0]
            name = Self.stripGitSuffix(parts[1])
        } else {
            let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            owner = parts[0]
            name = Self.stripGitSuffix(parts[1])
        }
        guard Self.isValidSegment(owner), Self.isValidSegment(name) else { return nil }
    }

    private static func stripGitSuffix(_ s: String) -> String {
        s.hasSuffix(".git") ? String(s.dropLast(4)) : s
    }

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")

    private static func isValidSegment(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
```

- [ ] **Step 5: Run tests** — Expected: PASS (5 tests). Also run the full suite: the new `SourceID` case must not break any existing switch (LumeKit has none that are exhaustive over it; the Task 1 helpers use `default:`).

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/ResourceTypes.swift Sources/LumeKit/GitHub/ Tests/LumeKitTests/GitHubRepoRefTests.swift
git commit -m "feat: SourceID.github + GitHubRepoRef parsing (slug, URL variants)"
```

---

### Task 3: `GitHubError` taxonomy + gh output mapping

**Files:**
- Create: `Sources/LumeKit/GitHub/GitHubError.swift`
- Test: `Tests/LumeKitTests/GitHubErrorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct GitHubErrorTests {
    private func map(stderr: String = "", stdout: String = "", path: String? = nil) -> GitHubError {
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
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'GitHubError' in scope`

- [ ] **Step 3: Create `Sources/LumeKit/GitHub/GitHubError.swift`**

```swift
import Foundation

/// Typed failures from the GitHub layer, each with a human message. `map`
/// classifies a failed `gh` invocation by its exit code, stderr, and (when
/// present) the JSON error body on stdout.
public enum GitHubError: Error, Equatable, Sendable {
    case ghNotInstalled
    case notAuthenticated
    case repoNotFound
    case branchNotFound
    case notFound(path: String)
    case writeConflict(path: String)
    case permissionDenied(path: String)
    case rateLimited
    case notUTF8(path: String)
    case network(detail: String)
    case protocolFailure(detail: String)

    public var userMessage: String {
        switch self {
        case .ghNotInstalled:
            return "GitHub CLI not found. Install it with `brew install gh`, then try again."
        case .notAuthenticated:
            return "Not signed in to GitHub. Run `gh auth login` in Terminal, then retry."
        case .repoNotFound:
            return "Repository not found — check the name, or sign in with an account that can see it."
        case .branchNotFound:
            return "That branch no longer exists on GitHub."
        case .notFound(let path):
            return "\(path) doesn't exist in this repository."
        case .writeConflict(let path):
            return "\((path as NSString).lastPathComponent) changed on GitHub since you opened it."
        case .permissionDenied:
            return "You don't have push access to this repository."
        case .rateLimited:
            return "GitHub rate limit reached. Try again in a few minutes."
        case .notUTF8(let path):
            return "\((path as NSString).lastPathComponent) isn't UTF-8 text."
        case .network(let detail):
            return "Network error: \(detail)"
        case .protocolFailure(let detail):
            return "GitHub error: \(detail)"
        }
    }

    /// Classify a failed gh invocation. Order matters: rate-limit responses
    /// are HTTP 403 and must win over the generic permission-denied 403;
    /// "No commit found for the ref" is a 404 and must win over repo/file 404.
    public static func map(exitCode: Int32, stdout: Data, stderr: Data, path: String?) -> GitHubError {
        let err = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (err + "\n" + String(decoding: stdout, as: UTF8.self)).lowercased()
        if combined.contains("rate limit") { return .rateLimited }
        if combined.contains("gh auth login") || combined.contains("not logged in") {
            return .notAuthenticated
        }
        if combined.contains("no commit found for the ref") { return .branchNotFound }
        if combined.contains("http 409") { return .writeConflict(path: path ?? "the file") }
        if combined.contains("http 422"), combined.contains("sha") {
            return .writeConflict(path: path ?? "the file")
        }
        if combined.contains("http 403") { return .permissionDenied(path: path ?? "the file") }
        if combined.contains("http 404") {
            if let path { return .notFound(path: path) }
            return .repoNotFound
        }
        if combined.contains("no such host") || combined.contains("dial tcp")
            || combined.contains("connection refused") || combined.contains("timeout")
            || combined.contains("network is unreachable") || combined.contains("could not resolve") {
            return .network(detail: err)
        }
        return .protocolFailure(detail: err.isEmpty ? "exit code \(exitCode)" : err)
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/GitHub/GitHubError.swift Tests/LumeKitTests/GitHubErrorTests.swift
git commit -m "feat: GitHubError taxonomy with gh output mapping"
```

---
### Task 4: `GitHubClient` (gh-CLI wrapper over `CommandRunning`)

**Files:**
- Create: `Sources/LumeKit/GitHub/GitHubClient.swift`
- Test: `Tests/LumeKitTests/GitHubClientTests.swift`

- [ ] **Step 1: Write the failing tests** (uses the existing `Tests/LumeKitTests/FakeCommandRunner.swift`)

```swift
import Testing
import Foundation
@testable import LumeKit

struct GitHubClientTests {
    private func makeClient(_ runner: FakeCommandRunner) -> GitHubClient {
        GitHubClient(runner: runner, ghPath: "/fake/gh")
    }

    @Test func missingGhThrowsBeforeRunningAnything() async {
        let runner = FakeCommandRunner()
        let client = GitHubClient(runner: runner, ghPath: nil)
        await #expect(throws: GitHubError.ghNotInstalled) {
            try await client.checkAuth()
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func checkAuthPassesAndFails() async throws {
        let ok = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        try await makeClient(ok).checkAuth()
        #expect(ok.calls[0].executable == "/fake/gh")
        #expect(ok.calls[0].arguments == ["auth", "status"])

        let bad = FakeCommandRunner(results: [FakeCommandRunner.fail("You are not logged into any GitHub hosts.")])
        await #expect(throws: GitHubError.notAuthenticated) {
            try await makeClient(bad).checkAuth()
        }
    }

    @Test func repoInfoParsesDefaultBranchAndPush() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"default_branch":"main","permissions":{"push":true,"pull":true}}"#),
        ])
        let info = try await makeClient(runner).repoInfo(slug: "o/r")
        #expect(info == GitHubRepoInfo(defaultBranch: "main", canPush: true))
        #expect(runner.calls[0].arguments == ["api", "repos/o/r"])
    }

    @Test func repoInfoWithoutPermissionsMeansNoPush() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"default_branch":"master"}"#),
        ])
        let info = try await makeClient(runner).repoInfo(slug: "o/r")
        #expect(info == GitHubRepoInfo(defaultBranch: "master", canPush: false))
    }

    @Test func listDirectoryBuildsEndpointAndParses() async throws {
        let listing = #"""
        [{"name":"docs","path":"docs","sha":"d1","size":0,"type":"dir"},
         {"name":"setup.md","path":"docs/setup.md","sha":"f1","size":12,"type":"file"}]
        """#
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let entries = try await makeClient(runner).listDirectory(slug: "o/r", path: "docs", ref: "main")
        #expect(runner.calls[0].arguments == ["api", "repos/o/r/contents/docs?ref=main"])
        #expect(entries == [
            GitHubDirEntry(name: "docs", type: "dir", size: 0, sha: "d1"),
            GitHubDirEntry(name: "setup.md", type: "file", size: 12, sha: "f1"),
        ])
    }

    @Test func listDirectoryRootAndPathEncoding() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("[]"), FakeCommandRunner.ok("[]"),
        ])
        let client = makeClient(runner)
        _ = try await client.listDirectory(slug: "o/r", path: "", ref: nil)
        #expect(runner.calls[0].arguments == ["api", "repos/o/r/contents"])
        _ = try await client.listDirectory(slug: "o/r", path: "my docs/sub", ref: "feature/x")
        #expect(runner.calls[1].arguments == ["api", "repos/o/r/contents/my%20docs/sub?ref=feature/x"])
    }

    @Test func readFileDecodesBase64AndKeepsSha() async throws {
        let b64 = Data("hello".utf8).base64EncodedString()
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":"\#(b64)\n","encoding":"base64","sha":"abc","size":5}"#),
        ])
        let file = try await makeClient(runner).readFile(slug: "o/r", path: "a.md", ref: "main")
        #expect(file == GitHubRemoteFile(data: Data("hello".utf8), sha: "abc"))
    }

    @Test func readFileFallsBackToBlobForLargeFiles() async throws {
        // Contents API truncates >1 MB: content empty, encoding "none".
        let b64 = Data("big".utf8).base64EncodedString()
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":"","encoding":"none","sha":"bigsha","size":2000000}"#),
            FakeCommandRunner.ok(#"{"content":"\#(b64)","encoding":"base64"}"#),
        ])
        let file = try await makeClient(runner).readFile(slug: "o/r", path: "big.md", ref: nil)
        #expect(file.data == Data("big".utf8))
        #expect(file.sha == "bigsha")
        #expect(runner.calls[1].arguments == ["api", "repos/o/r/git/blobs/bigsha"])
    }

    @Test func writeFilePutsJSONBodyOverStdinAndReturnsNewSha() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":{"sha":"new1"},"commit":{"sha":"c1"}}"#),
        ])
        let newSha = try await makeClient(runner).writeFile(
            slug: "o/r", path: "docs/a.md", content: Data("hi".utf8),
            message: "Update docs/a.md", sha: "old1", branch: "main")
        #expect(newSha == "new1")
        let call = runner.calls[0]
        #expect(call.arguments == ["api", "repos/o/r/contents/docs/a.md", "--method", "PUT", "--input", "-"])
        // sortedKeys encoding makes the body deterministic:
        let expectedBody = #"{"branch":"main","content":"\#(Data("hi".utf8).base64EncodedString())","message":"Update docs\/a.md","sha":"old1"}"#
        #expect(call.stdin == expectedBody)
    }

    @Test func listBranchesParsesNames() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"name":"main"},{"name":"feature/x"}]"#),
        ])
        let branches = try await makeClient(runner).listBranches(slug: "o/r")
        #expect(branches == ["main", "feature/x"])
        #expect(runner.calls[0].arguments == ["api", "repos/o/r/branches?per_page=100"])
    }

    @Test func listUserReposUsesRepoListJSON() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"nameWithOwner":"o/r","isPrivate":true}]"#),
        ])
        let repos = try await makeClient(runner).listUserRepos()
        #expect(repos == [GitHubRepoSummary(slug: "o/r", isPrivate: true)])
        #expect(runner.calls[0].arguments
                == ["repo", "list", "--limit", "200", "--json", "nameWithOwner,isPrivate"])
    }

    @Test func statDistinguishesDirectoryFromFile() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"name":"a","path":"d/a","sha":"s","size":1,"type":"file"}]"#),
            FakeCommandRunner.ok(#"{"name":"a.md","sha":"s2","size":42,"type":"file","content":"","encoding":"base64"}"#),
        ])
        let client = makeClient(runner)
        let dir = try await client.stat(slug: "o/r", path: "d", ref: "main")
        #expect(dir.isDirectory)
        let file = try await client.stat(slug: "o/r", path: "a.md", ref: "main")
        #expect(!file.isDirectory)
        #expect(file.size == 42)
    }

    @Test func apiFailureMapsThroughGitHubError() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("gh: Not Found (HTTP 404)"),
        ])
        await #expect(throws: GitHubError.repoNotFound) {
            _ = try await makeClient(runner).repoInfo(slug: "o/missing")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'GitHubClient' in scope`

- [ ] **Step 3: Create `Sources/LumeKit/GitHub/GitHubClient.swift`**

```swift
import Foundation

/// Repo metadata: default branch + whether the signed-in user can push.
public struct GitHubRepoInfo: Equatable, Sendable {
    public let defaultBranch: String
    public let canPush: Bool

    public init(defaultBranch: String, canPush: Bool) {
        self.defaultBranch = defaultBranch
        self.canPush = canPush
    }
}

/// One entry of a contents-API directory listing.
public struct GitHubDirEntry: Equatable, Sendable {
    public let name: String
    public let type: String     // "file" | "dir" | "symlink" | "submodule"
    public let size: Int64
    public let sha: String

    public init(name: String, type: String, size: Int64, sha: String) {
        self.name = name
        self.type = type
        self.size = size
        self.sha = sha
    }
}

/// A downloaded file: raw bytes + the blob sha captured at read time
/// (the optimistic-concurrency token for the next write).
public struct GitHubRemoteFile: Equatable, Sendable {
    public let data: Data
    public let sha: String

    public init(data: Data, sha: String) {
        self.data = data
        self.sha = sha
    }
}

/// One row of the "your repos" picker.
public struct GitHubRepoSummary: Equatable, Sendable, Identifiable {
    public let slug: String
    public let isPrivate: Bool

    public var id: String { slug }

    public init(slug: String, isPrivate: Bool) {
        self.slug = slug
        self.isPrivate = isPrivate
    }
}

/// Thin wrapper over the `gh` CLI: every operation is one subprocess through
/// `CommandRunning` (the same seam as ssh/sftp), so all logic above it is
/// unit-testable with `FakeCommandRunner`. Auth is gh's own (`gh auth login`)
/// — Lume never sees or stores a token.
public struct GitHubClient: Sendable {
    private let runner: CommandRunning
    private let ghPath: String?

    public init(runner: CommandRunning = ProcessRunner(), ghPath: String? = GitHubClient.locateGh()) {
        self.runner = runner
        self.ghPath = ghPath
    }

    /// Standard install locations first, then $PATH.
    public static func locateGh() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Non-interactive, no-noise environment for every gh call.
    private static let environment = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1",
    ]

    /// Throws `.notAuthenticated` unless `gh auth status` succeeds.
    public func checkAuth() async throws {
        guard let ghPath else { throw GitHubError.ghNotInstalled }
        let result = try await runner.run(ghPath, ["auth", "status"], stdin: nil,
                                          environment: Self.environment, timeout: 15)
        guard result.exitCode == 0 else { throw GitHubError.notAuthenticated }
    }

    public func repoInfo(slug: String) async throws -> GitHubRepoInfo {
        struct Raw: Decodable {
            let defaultBranch: String
            let permissions: Permissions?
            struct Permissions: Decodable { let push: Bool }
            enum CodingKeys: String, CodingKey {
                case defaultBranch = "default_branch", permissions
            }
        }
        let raw = try Self.decode(Raw.self, from: try await api("repos/\(slug)"))
        return GitHubRepoInfo(defaultBranch: raw.defaultBranch,
                              canPush: raw.permissions?.push ?? false)
    }

    public func listDirectory(slug: String, path: String, ref: String?) async throws -> [GitHubDirEntry] {
        struct Raw: Decodable { let name: String; let type: String; let size: Int64; let sha: String }
        let data = try await api(Self.contentsEndpoint(slug: slug, path: path, ref: ref),
                                 path: path.isEmpty ? "/" : path)
        do {
            return try JSONDecoder().decode([Raw].self, from: data)
                .map { GitHubDirEntry(name: $0.name, type: $0.type, size: $0.size, sha: $0.sha) }
        } catch {
            throw GitHubError.protocolFailure(detail: "\(path.isEmpty ? "/" : path) is not a directory")
        }
    }

    public func readFile(slug: String, path: String, ref: String?) async throws -> GitHubRemoteFile {
        struct Raw: Decodable { let content: String?; let encoding: String?; let sha: String }
        let raw = try Self.decode(Raw.self, from: try await api(
            Self.contentsEndpoint(slug: slug, path: path, ref: ref), path: path))
        if raw.encoding == "base64", let content = raw.content, !content.isEmpty,
           let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }) {
            return GitHubRemoteFile(data: decoded, sha: raw.sha)
        }
        // Contents API truncates files >1 MB (encoding "none"): re-fetch the blob by sha.
        struct Blob: Decodable { let content: String }
        let blob = try Self.decode(Blob.self,
                                   from: try await api("repos/\(slug)/git/blobs/\(raw.sha)", path: path))
        guard let decoded = Data(base64Encoded: blob.content.filter { !$0.isWhitespace }) else {
            throw GitHubError.protocolFailure(detail: "undecodable blob for \(path)")
        }
        return GitHubRemoteFile(data: decoded, sha: raw.sha)
    }

    /// PUT the contents API with the read-time sha; returns the new blob sha.
    public func writeFile(slug: String, path: String, content: Data, message: String,
                          sha: String, branch: String) async throws -> String {
        struct Body: Encodable { let message: String; let content: String; let branch: String; let sha: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // deterministic for tests
        let body = try encoder.encode(Body(message: message,
                                           content: content.base64EncodedString(),
                                           branch: branch, sha: sha))
        struct Resp: Decodable {
            let content: C
            struct C: Decodable { let sha: String }
        }
        let data = try await api("repos/\(slug)/contents/\(Self.encodePath(path))",
                                 method: "PUT", body: body, path: path)
        return try Self.decode(Resp.self, from: data).content.sha
    }

    public func listBranches(slug: String) async throws -> [String] {
        // One page of 100 covers typical repos — deliberate MVP cap (no --paginate).
        struct Raw: Decodable { let name: String }
        let data = try await api("repos/\(slug)/branches?per_page=100")
        return try Self.decode([Raw].self, from: data).map(\.name)
    }

    public func listUserRepos() async throws -> [GitHubRepoSummary] {
        guard let ghPath else { throw GitHubError.ghNotInstalled }
        // Deliberate MVP cap at 200; arbitrary repos remain reachable via manual entry.
        let result = try await runner.run(
            ghPath, ["repo", "list", "--limit", "200", "--json", "nameWithOwner,isPrivate"],
            stdin: nil, environment: Self.environment, timeout: 30)
        guard result.exitCode == 0 else {
            throw GitHubError.map(exitCode: result.exitCode, stdout: result.stdout,
                                  stderr: result.stderr, path: nil)
        }
        struct Raw: Decodable { let nameWithOwner: String; let isPrivate: Bool }
        return try Self.decode([Raw].self, from: result.stdout)
            .map { GitHubRepoSummary(slug: $0.nameWithOwner, isPrivate: $0.isPrivate) }
    }

    /// Directory vs file: the contents API returns a JSON array for
    /// directories and an object for files.
    public func stat(slug: String, path: String, ref: String?) async throws -> ResourceMeta {
        let data = try await api(Self.contentsEndpoint(slug: slug, path: path, ref: ref), path: path)
        let firstByte = data.first { !Set("\t\n\r ".utf8).contains($0) }
        if firstByte == UInt8(ascii: "[") { return ResourceMeta(isDirectory: true) }
        struct Raw: Decodable { let size: Int64? }
        let raw = try Self.decode(Raw.self, from: data)
        return ResourceMeta(isDirectory: false, size: raw.size)
    }

    // MARK: - Internals

    private func api(_ endpoint: String, method: String? = nil, body: Data? = nil,
                     path: String? = nil, timeout: TimeInterval = 30) async throws -> Data {
        guard let ghPath else { throw GitHubError.ghNotInstalled }
        var args = ["api", endpoint]
        if let method { args += ["--method", method] }
        if body != nil { args += ["--input", "-"] }
        let result = try await runner.run(ghPath, args, stdin: body,
                                          environment: Self.environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GitHubError.map(exitCode: result.exitCode, stdout: result.stdout,
                                  stderr: result.stderr, path: path)
        }
        return result.stdout
    }

    static func contentsEndpoint(slug: String, path: String, ref: String?) -> String {
        var endpoint = "repos/\(slug)/contents"
        if !path.isEmpty { endpoint += "/\(encodePath(path))" }
        if let ref { endpoint += "?ref=\(encodeRef(ref))" }
        return endpoint
    }

    /// Percent-encode each path segment (spaces, '#', '?', '%'), keeping "/".
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    /// Branch names: keep "/" (feature/x) — it's legal inside a query value.
    private static let refAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

    static func encodeRef(_ ref: String) -> String {
        ref.addingPercentEncoding(withAllowedCharacters: refAllowed) ?? ref
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GitHubError.protocolFailure(detail: "unexpected GitHub response") }
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (13 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/GitHub/GitHubClient.swift Tests/LumeKitTests/GitHubClientTests.swift
git commit -m "feat: GitHubClient — gh-CLI wrapper over CommandRunning"
```

---
### Task 5: `GitHubFileSource` (FileSource over one repo + branch, sha-tracked writes)

**Files:**
- Create: `Sources/LumeKit/GitHub/GitHubFileSource.swift`
- Test: `Tests/LumeKitTests/GitHubFileSourceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct GitHubFileSourceTests {
    private func makeSource(_ runner: FakeCommandRunner) -> GitHubFileSource {
        GitHubFileSource(slug: "o/r", client: GitHubClient(runner: runner, ghPath: "/fake/gh"))
    }

    private static func contentsJSON(_ text: String, sha: String) -> String {
        #"{"content":"\#(Data(text.utf8).base64EncodedString())","encoding":"base64","sha":"\#(sha)"}"#
    }

    @Test func listFiltersSortsSkipsSubmodulesAndBuildsRefs() async throws {
        let listing = #"""
        [{"name":"zeta.md","path":"zeta.md","sha":"1","size":5,"type":"file"},
         {"name":"docs","path":"docs","sha":"2","size":0,"type":"dir"},
         {"name":".git","path":".git","sha":"3","size":0,"type":"dir"},
         {"name":".secret","path":".secret","sha":"4","size":1,"type":"file"},
         {"name":".env","path":".env","sha":"5","size":1,"type":"file"},
         {"name":"vendored","path":"vendored","sha":"6","size":0,"type":"submodule"},
         {"name":"link.md","path":"link.md","sha":"7","size":1,"type":"symlink"}]
        """#
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let source = makeSource(runner)
        await source.setBranch("main")
        let nodes = try await source.list("/", includeHidden: false)
        // .git ignored always; .secret hidden; submodule skipped; folders first; .env visible.
        #expect(nodes.map(\.name) == ["docs", ".env", "link.md", "zeta.md"])
        #expect(nodes[0].isDirectory)
        #expect(nodes[2].isSymlink)
        #expect(nodes[1].ref == ResourceRef(sourceID: .github(slug: "o/r"), path: "/.env"))
        #expect(runner.calls[0].arguments == ["api", "repos/o/r/contents?ref=main"])
    }

    @Test func listOfSubdirectoryBuildsNestedPaths() async throws {
        let listing = #"[{"name":"a.md","path":"docs/a.md","sha":"1","size":1,"type":"file"}]"#
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let source = makeSource(runner)
        await source.setBranch("main")
        let nodes = try await source.list("/docs", includeHidden: false)
        #expect(nodes[0].ref.path == "/docs/a.md")
        #expect(runner.calls[0].arguments == ["api", "repos/o/r/contents/docs?ref=main"])
    }

    @Test func readCachesShaAndWriteSendsIt() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(Self.contentsJSON("hello", sha: "old1")),
            FakeCommandRunner.ok(#"{"content":{"sha":"new1"}}"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        let text = try await source.read("/docs/a.md")
        #expect(text == "hello")
        try await source.write("hello edited", to: "/docs/a.md")
        let put = runner.calls[1]
        #expect(put.arguments == ["api", "repos/o/r/contents/docs/a.md", "--method", "PUT", "--input", "-"])
        let stdin = put.stdin ?? ""
        #expect(stdin.contains(#""sha":"old1""#))
        #expect(stdin.contains(#""branch":"main""#))
        #expect(stdin.contains(#""message":"Update docs\/a.md""#))
    }

    @Test func successfulWriteUpdatesShaForConsecutiveSaves() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(Self.contentsJSON("v1", sha: "s1")),
            FakeCommandRunner.ok(#"{"content":{"sha":"s2"}}"#),
            FakeCommandRunner.ok(#"{"content":{"sha":"s3"}}"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        _ = try await source.read("/a.md")
        try await source.write("v2", to: "/a.md")
        try await source.write("v3", to: "/a.md")
        #expect(runner.calls[2].stdin?.contains(#""sha":"s2""#) == true)
    }

    @Test func writeWithoutPriorReadFailsClean() async {
        let source = makeSource(FakeCommandRunner())
        await source.setBranch("main")
        await #expect(throws: GitHubError.self) {
            try await source.write("text", to: "/never-read.md")
        }
    }

    @Test func setBranchClearsShaCache() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(Self.contentsJSON("v1", sha: "s1")),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        _ = try await source.read("/a.md")
        await source.setBranch("feature/x")
        await #expect(throws: GitHubError.self) {
            try await source.write("v2", to: "/a.md")   // stale sha was dropped
        }
        #expect(runner.calls.count == 1)                // no PUT was attempted
    }

    @Test func nonUTF8ContentThrowsNotUTF8() async {
        let binary = Data([0xFF, 0xFE, 0x00]).base64EncodedString()
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"{"content":"\#(binary)","encoding":"base64","sha":"b1"}"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        await #expect(throws: GitHubError.notUTF8(path: "/img.png")) {
            _ = try await source.read("/img.png")
        }
    }

    @Test func statRoutesThroughClient() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(#"[{"name":"a","path":"d/a","sha":"s","size":1,"type":"file"}]"#),
        ])
        let source = makeSource(runner)
        await source.setBranch("main")
        let meta = try await source.stat("/d")
        #expect(meta.isDirectory)
        #expect(runner.calls[0].arguments == ["api", "repos/o/r/contents/d?ref=main"])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'GitHubFileSource' in scope`

- [ ] **Step 3: Create `Sources/LumeKit/GitHub/GitHubFileSource.swift`**

```swift
import Foundation

/// `FileSource` over one GitHub repository + active branch. Every operation is
/// a `GitHubClient` call; reads capture each file's blob sha in actor state and
/// writes send it back — GitHub then rejects the PUT if the file changed
/// remotely (the conflict the UI surfaces as "reload or keep editing").
public actor GitHubFileSource: FileSource {
    public nonisolated let id: SourceID
    private let slug: String
    private let client: GitHubClient
    private var branch: String?
    /// Blob sha by ResourceRef-style path ("/docs/a.md"), captured at read time.
    private var shaByPath: [String: String] = [:]

    public init(slug: String, client: GitHubClient) {
        self.id = .github(slug: slug)
        self.slug = slug
        self.client = client
    }

    /// Switch the active branch. Cached shas belong to the old branch's blobs,
    /// so they're dropped — files must be re-read before they can be saved.
    public func setBranch(_ name: String) {
        branch = name
        shaByPath.removeAll()
    }

    /// "/docs/a.md" → "docs/a.md" (the contents API takes repo-relative paths).
    static func apiPath(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let entries = try await client.listDirectory(slug: slug, path: Self.apiPath(path), ref: branch)
        let base = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        return entries
            .filter { $0.type != "submodule" }   // not browsable content (MVP)
            .filter { TreeFilterRules.isVisible(name: $0.name, includeHidden: includeHidden) }
            .map { entry in
                ResourceNode(
                    ref: ResourceRef(sourceID: id, path: "\(base)/\(entry.name)"),
                    isDirectory: entry.type == "dir",
                    isSymlink: entry.type == "symlink"
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }  // folders first
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    public func read(_ path: String) async throws -> String {
        let file = try await client.readFile(slug: slug, path: Self.apiPath(path), ref: branch)
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw GitHubError.notUTF8(path: path)
        }
        shaByPath[path] = file.sha
        return text
    }

    public func write(_ text: String, to path: String) async throws {
        guard let branch else {
            throw GitHubError.protocolFailure(detail: "no active branch")
        }
        guard let sha = shaByPath[path] else {
            // Programmer-error guard: the editor always reads before saving.
            throw GitHubError.protocolFailure(detail: "write before read: \(path)")
        }
        let repoPath = Self.apiPath(path)
        let newSha = try await client.writeFile(
            slug: slug, path: repoPath, content: Data(text.utf8),
            message: "Update \(repoPath)", sha: sha, branch: branch)
        shaByPath[path] = newSha   // consecutive saves keep working
    }

    public func stat(_ path: String) async throws -> ResourceMeta {
        try await client.stat(slug: slug, path: Self.apiPath(path), ref: branch)
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (8 tests). Then the full suite (no regressions).

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/GitHub/GitHubFileSource.swift Tests/LumeKitTests/GitHubFileSourceTests.swift
git commit -m "feat: GitHubFileSource — FileSource over a repo+branch with sha-tracked writes"
```

---

### Task 6: `ConnectionStore` GitHub section (per-repo branch/path/recents)

**Files:**
- Modify: `Sources/LumeKit/SSH/ConnectionStore.swift`
- Test: `Tests/LumeKitTests/GitHubConnectionStoreTests.swift` (new file; existing `ConnectionStoreTests.swift` stays untouched)

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct GitHubConnectionStoreTests {
    private func makeStore() -> ConnectionStore {
        ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubConnectionStoreTests-\(UUID().uuidString).json"))
    }

    @Test @MainActor func decodesLegacyJSONWithoutGitHubSection() throws {
        let legacy = #"{"manualHosts":[],"hostState":{"web1":{"recentFiles":["/etc/a.conf"]}}}"#
        let state = try JSONDecoder().decode(ConnectionStoreState.self, from: Data(legacy.utf8))
        #expect(state.githubRepos.isEmpty)
        #expect(state.hostState["web1"]?.recentFiles == ["/etc/a.conf"])
    }

    @Test @MainActor func recordsBranchPathAndRecents() {
        let store = makeStore()
        store.noteRepoConnected(slug: "o/r")
        store.noteRepoBranch(slug: "o/r", branch: "feature/x")
        store.noteRepoBrowsed(slug: "o/r", path: "/docs")
        store.noteRepoOpened(slug: "o/r", file: "/docs/a.md")
        store.noteRepoOpened(slug: "o/r", file: "/docs/b.md")
        store.noteRepoOpened(slug: "o/r", file: "/docs/a.md")   // re-open moves to front
        let repo = store.state.githubRepos["o/r"]
        #expect(repo?.lastBranch == "feature/x")
        #expect(repo?.lastPath == "/docs")
        #expect(repo?.recentFiles == ["/docs/a.md", "/docs/b.md"])
        #expect(repo?.lastUsed != nil)
    }

    @Test @MainActor func recentFilesAreCapped() {
        let store = makeStore()
        for i in 0..<12 { store.noteRepoOpened(slug: "o/r", file: "/f\(i).md") }
        #expect(store.state.githubRepos["o/r"]?.recentFiles.count == 8)
        #expect(store.state.githubRepos["o/r"]?.recentFiles.first == "/f11.md")
    }

    @Test @MainActor func recentReposOrderedByLastUsed() async throws {
        let store = makeStore()
        store.noteRepoConnected(slug: "o/first")
        // Sleep between connects: ordering compares Date() stamps, and
        // back-to-back calls could otherwise tie.
        try await Task.sleep(for: .milliseconds(2))
        store.noteRepoConnected(slug: "o/second")
        #expect(store.recentGitHubRepos == ["o/second", "o/first"])
        try await Task.sleep(for: .milliseconds(2))
        store.noteRepoConnected(slug: "o/first")   // reconnect bumps it to the front
        #expect(store.recentGitHubRepos == ["o/first", "o/second"])
    }

    @Test @MainActor func roundTripsThroughDisk() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubConnectionStoreTests-rt-\(UUID().uuidString).json")
        let store = ConnectionStore(fileURL: url)
        store.noteRepoBranch(slug: "o/r", branch: "main")
        let reloaded = ConnectionStore(fileURL: url)
        #expect(reloaded.state.githubRepos["o/r"]?.lastBranch == "main")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `value of type 'ConnectionStoreState' has no member 'githubRepos'`

- [ ] **Step 3: Extend `ConnectionStoreState`** in `Sources/LumeKit/SSH/ConnectionStore.swift`

Add inside the struct (after `hostState`):

```swift
    /// Per-repo GitHub state, keyed by "owner/repo" slug. Additive field:
    /// the custom decoder below keeps pre-GitHub connections.json loading.
    public var githubRepos: [String: RepoState] = [:]

    public struct RepoState: Codable, Sendable, Equatable {
        public var lastBranch: String?
        public var lastPath: String?
        public var recentFiles: [String] = []
        public var lastUsed: Date?
        public init() {}
    }

    enum CodingKeys: String, CodingKey {
        case manualHosts, hostState, githubRepos
    }

    /// Tolerant decoding: every section is optional so older files (and
    /// future additive sections) load cleanly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manualHosts = try container.decodeIfPresent([SSHHost].self, forKey: .manualHosts) ?? []
        hostState = try container.decodeIfPresent([String: HostState].self, forKey: .hostState) ?? [:]
        githubRepos = try container.decodeIfPresent([String: RepoState].self, forKey: .githubRepos) ?? [:]
    }
```

(`encode(to:)` stays synthesized; declaring `CodingKeys` keeps it aligned.)

- [ ] **Step 4: Add the GitHub methods to `ConnectionStore`** (after `noteOpened`):

```swift
    // MARK: - GitHub repos

    public func noteRepoConnected(slug: String) {
        state.githubRepos[slug, default: .init()].lastUsed = Date()
        persist()
    }

    public func noteRepoBranch(slug: String, branch: String) {
        state.githubRepos[slug, default: .init()].lastBranch = branch
        persist()
    }

    public func noteRepoBrowsed(slug: String, path: String) {
        state.githubRepos[slug, default: .init()].lastPath = path
        persist()
    }

    public func noteRepoOpened(slug: String, file: String) {
        var repo = state.githubRepos[slug, default: .init()]
        repo.recentFiles.removeAll { $0 == file }
        repo.recentFiles.insert(file, at: 0)
        if repo.recentFiles.count > Self.recentsCap {
            repo.recentFiles.removeLast(repo.recentFiles.count - Self.recentsCap)
        }
        state.githubRepos[slug] = repo
        persist()
    }

    /// Most-recently-used repo slugs for the source switcher (capped).
    public var recentGitHubRepos: [String] {
        state.githubRepos
            .sorted { ($0.value.lastUsed ?? .distantPast) > ($1.value.lastUsed ?? .distantPast) }
            .prefix(Self.recentsCap)
            .map(\.key)
    }
```

- [ ] **Step 5: Run the new suite + `ConnectionStoreTests`** — Expected: PASS (5 + existing). The legacy-decode test is the critical one.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/SSH/ConnectionStore.swift Tests/LumeKitTests/GitHubConnectionStoreTests.swift
git commit -m "feat: ConnectionStore GitHub section — per-repo branch, path, recents"
```

---
### Task 7: `GitHubConnection` + AppState GitHub wiring

**Files:**
- Create: `Sources/Lume/Remote/GitHubConnection.swift`
- Modify: `Sources/Lume/AppState.swift` (GitHub lifecycle, bookkeeping helpers, conflict state)

No new unit tests (app target — see plan-header deviation 4); build + full suite green is the gate.

- [ ] **Step 1: Create `Sources/Lume/Remote/GitHubConnection.swift`**

```swift
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
```

- [ ] **Step 2: Add GitHub state + lifecycle to `AppState.swift`**

In the `// MARK: - Remote source (SSH)` property block, after `presentingNewConnection`, add:

```swift
    /// "Open GitHub Repo…" sheet visibility.
    var presentingOpenGitHubRepo = false
    /// "Browse Your Repos…" picker visibility.
    var presentingRepoBrowser = false
    /// Non-nil when a remote save hit a write conflict; drives the
    /// reload-or-keep-editing dialog (see DetailView).
    var pendingConflictReloadPath: String?
    /// Shared gh wrapper (stateless; auth lives in gh itself).
    let githubClient = GitHubClient()
```

In the `// MARK: - Remote source (SSH) — lifecycle` section, after `connectSSH`, add:

```swift
    func connectGitHub(_ ref: GitHubRepoRef) {
        // Re-picking the already-active repo just brings its tree back.
        if let remote, remote.sourceID == .github(slug: ref.slug) {
            showRemoteSource()
            if case .failed = remote.phase { Task { await remote.connect() } }
            return
        }
        let previous = remote
        Task { await previous?.disconnect() }
        let repoState = connections.state.githubRepos[ref.slug]
        let connection = GitHubConnection(
            ref: ref,
            client: githubClient,
            preferredBranch: repoState?.lastBranch,
            startPath: repoState?.lastPath)
        let session = RemoteSession(connection: connection, source: connection.source)
        remote = session
        showingRemote = true
        clearDocumentSelection()
        connections.noteRepoConnected(slug: ref.slug)
        Task { await session.connect() }
    }

    /// Switch the active branch: clears the open document (its buffer and sha
    /// belong to the old branch), re-roots the tree, records the choice.
    func switchGitHubBranch(_ branch: String) {
        guard let remote, let gh = remote.connection as? GitHubConnection,
              branch != gh.activeBranch else { return }
        clearDocumentSelection()
        connections.noteRepoBranch(slug: gh.ref.slug, branch: branch)
        Task {
            await gh.setActiveBranch(branch)
            await remote.reroot(to: "/")
        }
    }
```

- [ ] **Step 3: Replace the Task 1 `default:` arms with `.github` cases**

```swift
    /// Per-backend store bookkeeping: "user opened this remote file".
    private func noteRemoteOpened(_ path: String) {
        guard let remote else { return }
        switch remote.sourceID {
        case .ssh(let alias): connections.noteOpened(alias: alias, file: path)
        case .github(let slug): connections.noteRepoOpened(slug: slug, file: path)
        case .local: break
        }
    }

    /// Per-backend store bookkeeping: "user browsed to this remote directory".
    private func noteRemoteBrowsed(_ path: String) {
        guard let remote else { return }
        switch remote.sourceID {
        case .ssh(let alias): connections.noteBrowsed(alias: alias, path: path)
        case .github(let slug): connections.noteRepoBrowsed(slug: slug, path: path)
        case .local: break
        }
    }

    /// Recent files for the active remote (drives the tree's Recent section).
    var remoteRecentFiles: [String] {
        guard let remote else { return [] }
        switch remote.sourceID {
        case .ssh(let alias): return connections.state.hostState[alias]?.recentFiles ?? []
        case .github(let slug): return connections.state.githubRepos[slug]?.recentFiles ?? []
        case .local: return []
        }
    }
```

- [ ] **Step 4: Route write conflicts in `saveRemote`**

Replace `saveRemote`'s `catch` block:

```swift
            } catch GitHubError.writeConflict {
                pendingConflictReloadPath = path
            } catch {
                showNotice(remote.userMessage(for: error))
            }
```

And add the dialog's confirm action after `saveRemote`:

```swift
    /// "Reload" from the conflict dialog: discard the local buffer and
    /// re-read the remote version (which also re-captures the fresh sha).
    func confirmConflictReload() {
        guard let path = pendingConflictReloadPath else { return }
        pendingConflictReloadPath = nil
        chooseRemote(path)
    }
```

- [ ] **Step 5: Build + full test suite**

Run: `xcodegen generate && xcodebuild test ... 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED (no behavior reachable yet — UI lands next).

- [ ] **Step 6: Commit**

```bash
git add Sources/Lume/Remote/GitHubConnection.swift Sources/Lume/AppState.swift
git commit -m "feat: GitHubConnection lifecycle + AppState GitHub wiring and conflict state"
```

---

### Task 8: Source-switcher GitHub section + repo sheets

**Files:**
- Modify: `Sources/Lume/Remote/SourceSwitcherView.swift`
- Create: `Sources/Lume/Remote/OpenGitHubRepoSheet.swift`
- Create: `Sources/Lume/Remote/RepoBrowserSheet.swift`
- Modify: `Sources/Lume/SidebarView.swift` (attach the two sheets)

- [ ] **Step 1: Add the GitHub section to `SourceSwitcherView`'s menu**

After the "Saved Connections" section and before the `Divider()`, insert:

```swift
                if !app.connections.recentGitHubRepos.isEmpty {
                    Section("GitHub") {
                        ForEach(app.connections.recentGitHubRepos, id: \.self) { slug in
                            Button(slug) {
                                if let ref = GitHubRepoRef(parsing: slug) { app.connectGitHub(ref) }
                            }
                        }
                    }
                }
```

After `Button("New SSH Connection…") …`, add:

```swift
                Button("Open GitHub Repo…") { app.presentingOpenGitHubRepo = true }
                Button("Browse Your Repos…") { app.presentingRepoBrowser = true }
```

- [ ] **Step 2: Differentiate the GitHub icon in the switcher label**

Replace the `Image(systemName: …)` line in the menu label with:

```swift
                    Image(systemName: switcherIcon)
                        .foregroundStyle(app.showingRemote ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
```

and add the helper below `localTitle`:

```swift
    private var switcherIcon: String {
        guard app.showingRemote, let id = app.remote?.sourceID else { return "internaldrive" }
        if case .github = id { return "arrow.triangle.branch" }
        return "bolt.horizontal.circle.fill"
    }
```

Also update line 21's resurface button to show the right icon:

```swift
                        Label(remote.displayName,
                              systemImage: {
                                  if case .github = remote.sourceID { return "arrow.triangle.branch" }
                                  return "bolt.horizontal"
                              }())
```

- [ ] **Step 3: Create `Sources/Lume/Remote/OpenGitHubRepoSheet.swift`**

```swift
import SwiftUI
import LumeKit

/// Manual repo entry: an "owner/repo" slug or a pasted github.com URL.
struct OpenGitHubRepoSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""

    private var parsed: GitHubRepoRef? { GitHubRepoRef(parsing: input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open GitHub Repo")
                .font(.headline)
            TextField("owner/repo or github.com URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func open() {
        guard let ref = parsed else { return }
        app.connectGitHub(ref)
        dismiss()
    }
}
```

- [ ] **Step 4: Create `Sources/Lume/Remote/RepoBrowserSheet.swift`**

```swift
import SwiftUI
import LumeKit

/// Searchable picker over the signed-in user's repos (`gh repo list`).
struct RepoBrowserSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [GitHubRepoSummary] = []
    @State private var filter = ""
    @State private var phase: Phase = .loading

    enum Phase: Equatable { case loading, ready, failed(String) }

    private var filtered: [GitHubRepoSummary] {
        guard !filter.isEmpty else { return repos }
        return repos.filter { $0.slug.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your GitHub Repos")
                .font(.headline)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Can't Load Repos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .ready:
                    List(filtered) { repo in
                        Button {
                            if let ref = GitHubRepoRef(parsing: repo.slug) {
                                app.connectGitHub(ref)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(repo.slug).lineLimit(1)
                                Spacer()
                                if repo.isPrivate {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                        .help("Private")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .task {
            do {
                repos = try await app.githubClient.listUserRepos()
                phase = .ready
            } catch {
                phase = .failed((error as? GitHubError)?.userMessage ?? error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 5: Attach the sheets in `SidebarView.swift`**

After the existing `.sheet(isPresented: bindableApp.presentingNewConnection) { NewConnectionSheet() }` line, add:

```swift
        .sheet(isPresented: bindableApp.presentingOpenGitHubRepo) { OpenGitHubRepoSheet() }
        .sheet(isPresented: bindableApp.presentingRepoBrowser) { RepoBrowserSheet() }
```

- [ ] **Step 6: Build + full suite, then a quick smoke check**

Run: `xcodegen generate && xcodebuild test ... 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED. (Live behavior is verified by the Task 10 checklist.)

- [ ] **Step 7: Commit**

```bash
git add Sources/Lume/Remote/ Sources/Lume/SidebarView.swift
git commit -m "feat: GitHub source switcher section, open-repo sheet, repo browser"
```

---
### Task 9: Branch chip, read-only badge, conflict dialog, viewer copy

**Files:**
- Modify: `Sources/Lume/Remote/RemoteTreeView.swift` (GitHub header bar)
- Modify: `Sources/Lume/ContentView.swift` (conflict alert + viewer copy)

- [ ] **Step 1: Add the GitHub header bar to `RemoteTreeView`**

In the `.ready` case, before `goToBar`:

```swift
                case .ready:
                    if let gh = remote.connection as? GitHubConnection {
                        GitHubHeaderBar(connection: gh)
                        Divider()
                    }
                    goToBar
```

And append this view at the bottom of the file:

```swift
/// Branch picker + read-only badge for an active GitHub source.
private struct GitHubHeaderBar: View {
    @Environment(AppState.self) private var app
    let connection: GitHubConnection

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(connection.branches, id: \.self) { branch in
                    Button {
                        app.switchGitHubBranch(branch)
                    } label: {
                        if branch == connection.activeBranch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                    Text(connection.activeBranch ?? "—")
                        .font(.callout)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Commits go to this branch")

            Spacer(minLength: 4)

            if !connection.canPush {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("You don't have push access — saves will fail.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 2: Add the conflict-reload alert in `ContentView.swift`**

On `DetailView`'s outermost content (the `if/else` chain is a `@ViewBuilder` —
wrap it: put the modifier on the existing top-level container, or add a
`Group { … }` around the chain), attach:

```swift
        .alert(
            "File Changed on GitHub",
            isPresented: Binding(
                get: { app.pendingConflictReloadPath != nil },
                set: { if !$0 { app.pendingConflictReloadPath = nil } }
            )
        ) {
            Button("Reload (Discard My Edits)", role: .destructive) {
                app.confirmConflictReload()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            let name = ((app.pendingConflictReloadPath ?? "") as NSString).lastPathComponent
            Text("\(name) changed on GitHub since you opened it. Reload to get the latest version — your unsaved edits will be discarded. Keep editing to copy your changes out first.")
        }
```

(`@Environment(AppState.self) private var app` is already on `DetailView`; the
`Binding` above only reads/clears state, so no `@Bindable` is needed.)

- [ ] **Step 3: Generalize the remote viewer copy**

In `ContentView.swift`'s `remoteViewer(forPath:)`, replace the SSH-specific
fallback:

```swift
            case .pdf, .image, .html, .quickLook:
                ContentUnavailableView(
                    "Text Files Only",
                    systemImage: "doc.text",
                    description: Text("\(name) can't be previewed on a remote source — only text and config files open remotely.")
                )
```

- [ ] **Step 4: Build + full suite**

Run: `xcodegen generate && xcodebuild test ... 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lume/Remote/RemoteTreeView.swift Sources/Lume/ContentView.swift
git commit -m "feat: GitHub branch chip, read-only badge, conflict-reload dialog"
```

---

### Task 10: Manual integration checklist + README note

**Files:**
- Create: `docs/github-manual-test-checklist.md`
- Modify: `README.md` (if a "Remote sources" / features section exists, append; otherwise add a short section)

- [ ] **Step 1: Create `docs/github-manual-test-checklist.md`**

```markdown
# GitHub Backend — Manual Integration Checklist

Prereqs: `gh` installed and signed in (`gh auth status` green); one repo you
can push to (ideally with a second branch), one read-only repo (any public
repo you don't own).

## Auth & connect
1. [ ] With gh signed out (`gh auth logout`): Open GitHub Repo… → connect fails
       with the "gh auth login" message. Sign back in; Retry succeeds.
2. [ ] Open GitHub Repo… with `owner/repo` slug → tree appears at `/` on the
       default branch; branch chip shows it.
3. [ ] Open GitHub Repo… with a pasted `https://github.com/owner/repo` URL →
       same result.
4. [ ] Browse Your Repos… → list loads, filter narrows it, private repos show
       a lock; picking one connects.
5. [ ] Open a nonexistent repo (`owner/nope`) → "Repository not found" in the
       header with Retry.

## Browse & edit
6. [ ] Expand folders lazily; `.git`-style noise hidden; `.env` visible.
7. [ ] Go-to-path with `/docs` re-roots; with `/README.md` opens the file.
8. [ ] Open a Markdown file → editor renders; edit → dirty dot; ⌘S → saving
       indicator, then a new commit "Update README.md" appears on GitHub on
       the active branch.
9. [ ] Save again without re-opening → second commit lands (sha chain works).
10. [ ] Recent files list grows; clicking a recent re-opens it.

## Branches
11. [ ] Switch branches via the chip → tree re-roots, open file closes;
        editing + ⌘S commits to the new branch. Reconnecting later lands on
        the last-used branch.

## Conflicts & permissions
12. [ ] Open a file, edit it on github.com, then ⌘S in Lume → conflict dialog;
        Keep Editing leaves the buffer dirty; ⌘S again → dialog again;
        Reload fetches the remote version; a subsequent edit + ⌘S commits.
13. [ ] Open the read-only repo → Read-only badge appears; ⌘S on an edit →
        "You don't have push access" notice and the buffer stays dirty.

## Edge cases
14. [ ] A file >1 MB opens (blob fallback).
15. [ ] A binary file (image) shows the unsupported pane, not garbage.
16. [ ] Switch to Local and back → GitHub tree state is preserved;
        Disconnect → switcher returns to Local; repo appears under recents.
```

- [ ] **Step 2: Add a README note**

Append to the existing remote/SSH feature blurb (or create a "Remote sources"
section if none):

```markdown
### GitHub repos

Open any GitHub repository from the source switcher (`owner/repo`, a pasted
URL, or the Browse Your Repos picker — requires the [gh CLI](https://cli.github.com)
signed in via `gh auth login`). Browse the repo tree, pick a branch, and edit
text/config files with Lume's editors; ⌘S commits directly to the active
branch ("Update <path>"). If the file changed on GitHub since you opened it,
the save is rejected and Lume offers to reload — your edits are never silently
lost, and neither are anyone else's.
```

- [ ] **Step 3: Run the checklist** against a real repo. Record any failures as findings — do not mark this task complete with open failures.

- [ ] **Step 4: Final full suite**

Run: `xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -20`
Expected: TEST SUCCEEDED — all suites.

- [ ] **Step 5: Commit**

```bash
git add docs/github-manual-test-checklist.md README.md
git commit -m "docs: GitHub backend manual test checklist + README note"
```





