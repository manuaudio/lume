# All-Encompassing Favorites (local + SSH + GitHub) — Design

**Date:** 2026-06-15
**Status:** Approved for planning
**Builds on:** the SSH remote MVP (`2026-06-10-ssh-remote-file-sources-design.md`)
and the GitHub backend (`2026-06-11-github-backend-design.md`). Both shipped a
per-source recents list but kept global pinning disabled while remote.

## Goal

Let the user pin local files, SSH paths, and GitHub repo files into **one**
Favorites list, with each remote item carrying a small source badge. Clicking a
remote favorite connects to its source (if needed) and opens it — the same
quick-jump feel a local favorite has today. Storage stays on this Mac (no
cross-machine sync in this round).

## Decisions (settled during brainstorming)

| Question | Decision |
|---|---|
| Scope | One list, any source. Local + SSH (host+path) + GitHub (repo+path). No server sync (deferred). |
| GitHub branch identity | Favorite = repo + path only. Opens on the repo's default (or last-used) branch — not branch-pinned. |
| Disconnected display | Remote favorites always shown, each with a source badge. Click connects-then-opens. Unreachable source → error on click; favorite stays. |
| Storage strategy | Approach A: a separate `RemoteFavorite` SwiftData model; existing `Favorite` table untouched. The "one list" is a view-model merge. |
| Migration | Additive new model via an explicit `LumeSchemaV2` + a `.lightweight` stage — exactly the "next schema change" the schema code anticipates. |

**Why a separate model (not extending `Favorite`):** `Favorite` keys on
`@Attribute(.unique) path: String` and its whole renderer is local-URL-coupled
(`URL(fileURLWithPath:)`, inline folder expansion via `FileSystemCache`).
Remote items can't reuse any of that, and two hosts can legitimately pin the
same path string (`/etc/nginx.conf`), so `path` can't stay the unique key for
remote rows. Extending `Favorite` would require changing its unique attribute —
a custom backfilling migration the code explicitly warns is delicate. A new
additive model avoids all of it and mirrors the prior Bookmark/Favorite split.

## Architecture

### 1. Data model (`Sources/LumeKit/Library/Models.swift`)

```swift
@Model public final class RemoteFavorite {
    @Attribute(.unique) public var ref: String   // dedup key: "kind:key:path"
    public var sourceKindRaw: String              // "ssh" | "github"
    public var sourceKey: String                  // host alias "web1" | slug "owner/repo"
    public var path: String                       // remote path
    public var isDirectory: Bool                  // folder → reroot; file → open
    public var dateAdded: Date
    public var sortIndex: Int                      // shared ordering space with Favorite

    public init(ref: String, sourceKindRaw: String, sourceKey: String,
                path: String, isDirectory: Bool, dateAdded: Date = .now, sortIndex: Int = 0) { … }
}
```

- `ref` = `"\(sourceKindRaw):\(sourceKey):\(path)"`, e.g.
  `ssh:web1:/etc/nginx.conf`, `github:manuaudio/lume:/docs/setup.md`. It is the
  unique dedup key only; the three component fields are stored separately so
  nothing parses `ref` back (robust to colons in remote paths).
- Two hosts pinning the same path → distinct `ref`s → distinct rows (the
  collision this model exists to solve).
- The active GitHub branch is **not** part of identity (repo-only, default
  branch on open).

### 2. Migration (`LumeSchema.swift`, `LibraryContainerFactory.swift`)

This is the "next schema change" the existing comments anticipate:

- Add `LumeSchemaV2` whose `models` = V1's list **+ `RemoteFavorite`**.
- Add a `.lightweight` `MigrationStage(.lightweight, fromVersion: V1, toVersion: V2)`
  to `LumeMigrationPlan.stages`. Adding a new entity needs no per-row transform,
  no backfill, and creates no uniqueness conflict — so lightweight is correct
  and safe.
- `LibraryContainerFactory.make` builds `Schema(versionedSchema: LumeSchemaV2.self)`
  and passes `LumeMigrationPlan` to the `ModelContainer`.
- Vestigial `Bookmark` stays in V2 (deferred drop) — one concern per change.

### 3. Store API (`Sources/LumeKit/Library/LibraryStore.swift`)

```swift
func addRemoteFavorite(ref:sourceKind:sourceKey:path:isDirectory:)
func removeRemoteFavorite(ref:)
func isRemoteFavorite(ref:) -> Bool
func remoteFavorites() -> [RemoteFavorite]          // sorted by sortIndex, dateAdded
func reorderAllFavorites(_ ordered: [FavoriteRef]) // rewrites shared sortIndex across both tables
```

where `FavoriteRef` is a small value type the UI already has per row:

```swift
enum FavoriteRef: Hashable { case local(path: String); case remote(ref: String) }
```

`reorderAllFavorites` takes the heterogeneous ordered list (local paths +
remote refs) and rewrites the single shared `sortIndex` space so local and
remote rows interleave in user order.

### 4. AppState + UI

- **Unified row type:**
  ```swift
  enum FavoriteItem: Identifiable {
      case local(Favorite)          // unchanged inline-expand behavior
      case remote(RemoteFavorite)   // leaf jump-point + source badge
  }
  ```
  `AppState.allFavoriteItems` merges `[Favorite]` + `[RemoteFavorite]` sorted by
  the shared `sortIndex`.
- **Pinning (remote):** while an SSH/GitHub source is active, the remote tree
  rows and the open-file toolbar gain the same pin affordance local files have.
  `toggleRemoteFavorite(_ node: ResourceNode)` builds `ref` from the active
  `sourceID` + node path and calls the store. This lifts the SSH/GitHub spec's
  "pinning disabled while remote" rule — *for global pinning only*; per-source
  recents are unchanged.
- **Rendering:** local rows render exactly as today (folders expand inline via
  the cache). Remote rows render as single rows with a source glyph
  (`⚡ alias` for SSH, branch-icon + `slug` for GitHub) plus the filename.
- **Clicking a remote favorite** (`openRemoteFavorite(_:)`):
  - source not active → `connectSSH(SSHHost(alias:))` /
    `connectGitHub(GitHubRepoRef(parsing: slug))` first (reuses existing
    lifecycle incl. per-repo last-branch resolution),
  - then file → `chooseRemote(path)`; directory → reroot the remote tree to
    that path,
  - already on that source → skip connect, go straight to open/reroot.
- **Reorder & unpin:** drag-reorder operates on the merged list and rewrites
  the shared `sortIndex`. Unpin is the same filled/empty pin toggle, removing
  from whichever table owns the row.

### 5. Error handling

- **Stale source** (host removed from `~/.ssh/config` + manual store, repo
  deleted/renamed, missing remote path): the favorite always renders. On click,
  the existing connect/open error surfaces normally (SSH host-unreachable →
  header error; GitHub 404 → "Repository not found"; missing file → `notFound`
  notice). Nothing auto-removes a favorite; the user unpins it.
- **Manual-host SSH favorites:** alias is the key; the manual host's connection
  details already live in `ConnectionStore`. If that manual host was deleted,
  clicking shows the connect error — the user re-adds the connection.
- **Duplicate pin:** unique `ref` makes a second pin of the same item a no-op.
- **Path collisions:** local and remote favorites with equal path strings never
  collide (separate tables, separate keys).

### 6. Scope boundary

This change touches favorites only. The other still-local-only affordances
(tags, scans, file-ops, watcher) stay disabled while remote — no scope creep.

## Testing

- **Unit (LumeKit):** `RemoteFavorite` round-trips through `LibraryStore`
  (add/remove/isRemoteFavorite/list); `ref` composition for ssh vs github;
  `reorderAllFavorites` rewrites the shared `sortIndex` across both tables in
  the given order.
- **Migration regression (critical):** a store written under `LumeSchemaV1`
  (local favorites only) opens under `LumeSchemaV2` with all local favorites
  intact and the new `RemoteFavorite` table usable — zero data loss.
- **Manual checklist:** pin an SSH file + a GitHub file; switch to Local;
  confirm both show with badges; click each from a disconnected state →
  connects + opens; pin a remote folder → reroots; unpin; reorder across the
  local/remote boundary; delete the underlying host/repo → click shows error
  and the favorite persists.

## Non-goals (this round)

- Cross-machine favorites sync (the original sub-project 3 server-sync idea) —
  separate spec, builds on this storage.
- Inline expansion of a pinned *remote* folder in the Favorites region (remote
  folder favorites reroot the tree instead).
- Branch-pinned GitHub favorites.
- Migrating tags/scans/file-ops/watcher to work remotely.

## Build order (for the implementation plan)

1. `RemoteFavorite` model + `LumeSchemaV2` + `.lightweight` migration stage +
   container factory wiring; migration-regression test.
2. `LibraryStore` remote-favorite CRUD + `reorderAllFavorites`; round-trip tests.
3. `AppState` merged `FavoriteItem` list + `toggleRemoteFavorite` +
   `openRemoteFavorite` + `isRemoteFavorite(node:)`.
4. Sidebar Favorites region: render remote rows with badges; pin affordance on
   remote tree rows + open-file toolbar.
5. Reorder across the merged list; unpin; error surfaces; manual checklist.
