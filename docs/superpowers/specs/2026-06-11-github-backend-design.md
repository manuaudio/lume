# GitHub Repo Editing Backend (MVP) — Design

**Date:** 2026-06-11
**Status:** Approved for planning
**Sub-project:** 2 of 3 (SSH → GitHub → remote favorites sync). Builds on the
`FileSource` foundation shipped with the SSH MVP
(`docs/superpowers/specs/2026-06-10-ssh-remote-file-sources-design.md`).

## Goal

Open a GitHub repository in Lume's sidebar, browse it, and make quick edits
that commit directly to a chosen branch on ⌘S — using Lume's existing editors,
with the same look and feel as the SSH remote experience.

**Primary workflow:** quick targeted edits (docs, configs, YAML) committed
straight to a branch. Not a PR workflow, not a local clone manager.

## Decisions (settled during brainstorming)

| Question | Decision |
|---|---|
| Save semantics | Direct commit to the active branch on ⌘S (like editing on github.com) |
| Transport / auth | Shell out to the `gh` CLI via the existing `CommandRunning` seam; auth is `gh auth login` — Lume never stores a token |
| Repo picking | Both: manual entry (owner/repo or URL) **and** a searchable "your repos" picker (`gh repo list`) |
| Branches | Branch picker over existing branches; open at last-used (else default) branch; no branch creation in MVP |
| Commit message | Auto-generated ("Update <path>"), no prompt |
| Conflict on save | Fail + offer Reload; buffer stays dirty; no force-overwrite, no merge |
| Integration strategy | Approach A: generalize `RemoteSession` over `any FileSource` + a per-backend `RemoteConnection` lifecycle protocol — pays the unification debt the SSH plan explicitly deferred to this sub-project |

**Known tension (accepted, same as SSH):** shelling out to `gh` is
incompatible with the App Sandbox. `GitHubClient` is the contained swap point
(e.g. to URLSession + Keychain-stored token) if/when Lume sandboxes;
everything above its public surface is transport-agnostic.

## Architecture

### 1. LumeKit — `GitHub/` (UI-free, unit-tested)

```
Sources/LumeKit/GitHub/
├── GitHubRepoRef.swift      owner/name parsing (slug or github.com URL), display name
├── GitHubError.swift        typed errors + gh stderr/JSON → error mapping
├── GitHubClient.swift       thin gh-CLI wrapper over CommandRunning
└── GitHubFileSource.swift   actor: FileSource impl + per-path sha cache
```

`SourceID` (in `ResourceTypes.swift`) gains one case:

```swift
public enum SourceID: Hashable, Sendable {
    case local
    case ssh(alias: String)
    case github(slug: String)   // "owner/repo" — branch is session state, not identity
}
```

`FileSource`, `TreeFilterRules`, `ResourceRef`/`ResourceNode`/`ResourceMeta`
are reused untouched.

- **`GitHubRepoRef`** — pure value type: parses `owner/repo` slugs and pasted
  `github.com` URLs (https, with/without `.git`, tree/blob deep links reduced
  to the repo); rejects junk with a typed error. Provides `slug` and a display
  name.
- **`GitHubClient`** — every operation is one `gh` invocation through
  `CommandRunning` (the exact ssh/sftp pattern, so `FakeCommandRunner` and the
  SSH test approach carry over). Operations:
  - `repoInfo(slug)` — `gh api repos/{slug}`: default branch + `permissions.push`
  - `listDirectory(slug, path, ref)` — contents API with `?ref=`
  - `readFile(slug, path, ref)` — contents API (base64 + sha); files >1 MB
    fall back to the blob API by sha (contents API truncates large files)
  - `writeFile(slug, path, content, message, sha, branch)` — `PUT contents`
  - `listBranches(slug)` — paginated branch names
  - `listUserRepos()` — `gh repo list` (name, private flag)
  - `authStatus()` — `gh auth status`
  - The `gh` binary is resolved from the standard install locations + `PATH`;
    missing → `GitHubError.ghNotInstalled` with an install hint.
- **`GitHubFileSource`** (actor) — implements `FileSource` for one repo +
  active branch:
  - `list` maps contents-API entries to `ResourceNode`s, filtered through
    `TreeFilterRules` (visibility parity with local/SSH), folders first.
    `type: "submodule"` entries are skipped; symlinks render as files
    (same MVP stance as SSH).
  - `read` decodes base64 content and **caches the blob sha per path** in
    actor state.
  - `write` sends the cached sha (the optimistic-concurrency token) with the
    auto message `Update <path>`; on success it stores the new sha returned
    by the API, so consecutive saves keep working. A write without a prior
    read fails cleanly (programmer-error guard, not a user flow).
  - `stat` derives from contents-API metadata (`isDirectory`, `size`;
    `mode` is nil — GitHub has no POSIX modes).
  - Branch switching = `setBranch(_:)` which clears the sha cache.
  - Non-UTF-8 / binary content routes to the existing "unsupported" pane.

### 2. App target — `RemoteSession` generalization (Approach A)

The unification the SSH plan deferred "to the GitHub sub-project, which
actually needs it" lands **first**, before any GitHub code, with the full
existing test suite as the regression net:

```
Sources/Lume/Remote/
├── RemoteConnection.swift    NEW protocol — per-backend lifecycle:
│       sourceID, displayName, connect() async throws -> rootPath,
│       error → user-message mapping
├── RemoteSession.swift       GENERALIZED — owns `any RemoteConnection` +
│       `any FileSource` + the tree state it already has
│       (children/expanded/loading/reroot are already source-agnostic:
│       they only call source.list)
├── SSHConnection.swift       extracted from today's RemoteSession
│       (ControlMaster connect + realpath of start path)
└── GitHubConnection.swift    gh auth check → repoInfo (validates repo,
        gets default branch + push permission) → root at per-repo
        last path (else "/")
```

Branch is **session state**: `GitHubConnection` exposes the branch list,
active branch, and push permission; `RemoteSession` stays branch-agnostic.
Switching branches re-roots the tree at `/`, clears children and the source's
sha cache, and records the choice in the connection store.

`AppState`'s remote section keys behavior off `SourceID` where backends differ
(e.g. recents bookkeeping) and is otherwise unchanged — `select/save` routing,
save indicator, and error surfaces are shared.

### 3. UI

- **Source switcher** gains a GitHub section, parallel to the SSH hosts list:
  recent repos (from the connection store), "Browse Your Repos…", and
  "Open GitHub Repo…".
  - *Open GitHub Repo…* — small sheet, one field accepting `owner/repo` or a
    pasted github.com URL.
  - *Browse Your Repos…* — searchable picker over `gh repo list` results
    (name + private badge). Both routes land in the same connect flow.
- **Connect flow:** `gh auth status` → repo metadata → `.ready` on the
  last-used branch for this repo (else the default branch), rooted at the
  per-repo last path (else `/`) — same restore behavior as SSH hosts.
  Failures use the same header error + Retry surface as SSH.
- **Header:** repo name + a **branch chip** — a menu of branches (fetched on
  first open). If the user lacks push access, a read-only badge appears so a
  failing save is never a surprise.
- **Browse / open / edit:** identical to SSH from the user's perspective —
  lazy tree expand (one contents-API call per directory), go-to-path within
  the repo, per-repo recent files, files open through `DocumentRouter`
  (Markdown/config/.env editors all work on GitHub content).
- **Save (⌘S):** saving indicator → PUT with auto message to the active
  branch → new sha cached → indicator clears. Buffer-dirty-until-confirmed
  semantics unchanged from SSH.
- **Conflict path:** PUT rejected (sha mismatch) → notice
  "*path* changed on GitHub since you opened it", buffer stays dirty, with a
  **Reload** action that fetches the remote version — applied only after an
  explicit "discard your edits?" confirmation.
- **Disabled while remote:** same set as SSH — favorites/pinning, tags,
  scans, file-ops, watcher.

### 4. Persistence

`connections.json` (existing `ConnectionStore`) grows an optional `github`
section: recent repos with per-repo `{lastBranch, recentFiles, lastPath}` and
last-used ordering. Additive Codable field with a default value, so existing
files load unchanged.

### 5. Error handling

Typed `GitHubError` enum, each case with a `userMessage` (mirrors `SSHError`):

| Case | Trigger | Behavior |
|---|---|---|
| `ghNotInstalled` | gh binary not found | Connect fails with install hint (`brew install gh`) |
| `notAuthenticated` | `gh auth status` non-zero | "Sign in with `gh auth login` in Terminal, then retry" |
| `repoNotFound` | 404 on repo metadata | Connect error in header (also covers no-read-access private repos — GitHub 404s those) |
| `writeConflict(path:)` | 409/422 sha mismatch on PUT | Reload-or-stay-dirty flow |
| `permissionDenied(path:)` | 403 on PUT | "You don't have push access" — matches the read-only badge |
| `branchNotFound` | 404 on ref | Branch menu refreshes; fall back to default branch |
| `rateLimited(resetAt:)` | 403 + rate-limit headers | Notice with retry time; tree unchanged |
| `network(detail:)` | gh failure with network stderr | Header error + Retry |
| `protocolFailure(detail:)` | anything else | Fallback; raw detail preserved |

Mapping is one function classifying gh's exit code + stderr + (when present)
the JSON error body, unit-tested against canned gh outputs like `SSHError.map`.

### 6. Testing

- **Unit (LumeKit, no network, via `FakeCommandRunner`):**
  - `GitHubRepoRef` parsing: slugs, URL variants, junk rejection.
  - `GitHubError` mapping from canned gh stderr / JSON bodies.
  - `GitHubClient` command-shape assertions: correct `gh api` paths, `?ref=`
    propagation, PUT body contains sha/branch/message, base64 encode/decode.
  - `GitHubFileSource`: list filtering + folders-first parity, submodule
    skipping, sha-cache behavior (write sends captured sha; success updates
    it; write-without-read fails clean), >1 MB blob-API fallback.
- **Regression net:** the full existing suite must stay green through the
  `RemoteSession` generalization — the riskiest step, which lands first.
- **Integration (manual):** checklist like the SSH one — auth states, open
  repo both ways, branch switch, edit+save, conflict (edit the same file on
  github.com mid-session), read-only repo, large file, binary file.

## Non-goals (MVP)

- PR flow, branch creation, multi-file/batched commits
- Git history UI, diffs, blame
- File create/rename/delete on the remote (matches SSH MVP)
- Submodules, LFS content
- Custom commit messages (auto-generated only; an optional-edit affordance is
  a natural follow-up)
- Sandbox-compatible transport (documented swap point only)
- GitHub Enterprise hosts (gh supports them; deliberately untested in MVP)

## Build order (for the implementation plan)

1. Generalize the remote layer: `RemoteConnection` protocol, `RemoteSession`
   over `any FileSource`, extract `SSHConnection` — full suite green, no
   visible change.
2. `SourceID.github` + `GitHubRepoRef` + `GitHubError` (pure types + mapping).
3. `GitHubClient` over `CommandRunning` (command shapes, auth, repo info,
   list/read/write/branches).
4. `GitHubFileSource` (list/read/stat, then sha-tracked write).
5. `GitHubConnection` + `ConnectionStore` github section.
6. UI: switcher section, open-repo sheet, repo browser picker, branch chip,
   read-only badge.
7. Conflict/error surfaces, manual integration checklist, README note.
