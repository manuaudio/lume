# Cross-Machine Favorites Sync (iCloud) — Design

**Date:** 2026-06-17
**Status:** Approved for planning
**Sub-project:** 3 of 3 (SSH → GitHub → favorites sync). Builds on the
all-encompassing favorites storage
(`2026-06-15-all-encompassing-favorites-design.md`).

## Goal

Keep a user's **remote favorites** (SSH + GitHub) and **manual SSH
connections** in sync across their own Macs, via iCloud — so pinning a remote
file on the laptop makes it appear on the desktop, and a manual host added on
one Mac is connectable from the other. No servers, no accounts, no sharing
with other people.

## Decisions (settled during brainstorming)

| Question | Decision |
|---|---|
| Use case | The user's own Macs, via iCloud (same Apple ID). Not a server, not manual export. |
| What syncs | Remote favorites (SSH/GitHub) **and** manual SSH connections. NOT: local-file favorites, the private key itself, ssh-config hosts, recents, GitHub repo recents. |
| Local favorites | Excluded — absolute paths rarely resolve across Macs. They stay per-machine. |
| Deletions | Propagate, via tombstones — unpin on one Mac removes it on the other. |
| Transport | Approach A: a single JSON document in the iCloud ubiquity container + a hand-rolled three-way merge. NOT CloudKit-mirrored SwiftData. |

**Why not CloudKit-mirrored SwiftData:** CloudKit mirroring forbids
`@Attribute(.unique)` — it would force dropping the unique constraints on
`Favorite.path` and `RemoteFavorite.ref` (the dedup design's core) plus a V3
migration making every attribute optional. And manual connections live in JSON
(`ConnectionStore`), not SwiftData, so they wouldn't sync that way at all. The
JSON-document approach sidesteps both, reuses the established `ConnectionStore`
pattern, and keeps the merge a small, pure, unit-testable function.

## Architecture

### 1. The sync document (`SyncDocument`, LumeKit, `Codable`)

A single JSON file at
`~/Library/Mobile Documents/iCloud~com~lume~Lume/Documents/favorites-sync.json`:

```json
{
  "schemaVersion": 1,
  "remoteFavorites": [
    { "ref": "ssh:web1:/etc/nginx.conf", "sourceKind": "ssh", "sourceKey": "web1",
      "path": "/etc/nginx.conf", "isDirectory": false,
      "updatedAt": "2026-06-17T10:00:00Z", "deleted": false }
  ],
  "manualHosts": [
    { "alias": "web1", "hostname": "10.0.0.5", "user": "deploy", "port": 2222,
      "identityFile": "~/.ssh/id_prod",
      "updatedAt": "2026-06-17T10:00:00Z", "deleted": false }
  ]
}
```

- **Identity:** `ref` for a remote favorite, `alias` for a manual host.
- **`updatedAt`** (wall-clock ISO-8601) + **`deleted`** (tombstone) per item.
  These live ONLY in the document + engine — there is **no SwiftData schema
  change** and no V3 migration. SwiftData stays the untouched local source of
  truth.
- **No `sortIndex`** in the wire format — drag-order is per-machine (syncing
  order is a separate, deferred concern).
- **`identityFile` is a path string**, never the key contents. The engine
  stores it tilde-relative (`~/.ssh/id_prod`) when under the home dir so it
  resolves across Macs with different usernames; the private key is never
  synced.

### 2. The merge (`SyncMerge`, LumeKit, pure, no I/O)

```swift
SyncMerge.merge(baseline: SyncDocument, local: SyncDocument,
                incoming: SyncDocument) -> SyncDocument
```

A **three-way merge**:
- `baseline` = the last document this Mac synced (persisted in Application
  Support).
- `local` = current local state, stamped against the baseline — items changed
  since baseline get `updatedAt = now`; items that vanished locally become
  tombstones (`deleted: true`, `updatedAt = now`).
- `incoming` = the document just read from iCloud.

Per identity, **last-writer-wins by `updatedAt`**: the newer timestamp wins; a
winning tombstone removes the item, otherwise it's upserted. Tombstones past a
**30-day horizon** are pruned to bound file growth. Pure and fully testable
without iCloud. Clock skew across Macs is the known LWW weakness — acceptable
for low-stakes, rarely-concurrent favorites (no vector clocks; YAGNI).

### 3. The engine (`FavoritesSyncEngine`, LumeKit, `@MainActor`)

A thin I/O shell that owns all stateful work and delegates merging to
`SyncMerge`:

- **Read local:** project current `RemoteFavorite`s (`LibraryStore`) + manual
  hosts (`ConnectionStore`) into a `SyncDocument`.
- **Observe:** an `NSMetadataQuery` scoped to the ubiquity container watching
  `favorites-sync.json`, firing when another Mac pushes a change.
- **Sync tick:** read incoming (NSFileCoordinator-coordinated) →
  `SyncMerge.merge(baseline, local, incoming)` → **apply** the merged
  non-tombstoned set into `LibraryStore` + `ConnectionStore` (upsert/delete) →
  `refreshLibrary()` → write merged back to iCloud (coordinated) → persist it
  as the new baseline.
- **Triggers:** on launch (after stores load); on local mutation (pin/unpin,
  manual host add/remove), debounced; on each `NSMetadataQuery` change.
- All iCloud file access is `NSFileCoordinator`-coordinated (the same
  mechanism `TextDocument` uses), so a simultaneous write from the other Mac
  can't clobber. iCloud handles the file transfer.

### 4. Integration

- `AppState` owns the `FavoritesSyncEngine`, created once `LibraryStore` +
  `ConnectionStore` have loaded.
- Local mutations already funnel through `toggleRemoteFavorite` /
  `removeRemoteFavorite` and `ConnectionStore.addManualHost` /
  `removeManualHost`; each schedules a debounced outbound sync.
- **Feedback-loop guard:** while the engine applies an incoming change to the
  stores, an `isApplying` flag suppresses the outbound-sync trigger, so an
  applied change doesn't re-stamp `updatedAt` and ping-pong between Macs.
- **Apply uses existing store APIs:** `LibraryStore.addRemoteFavorite` /
  `removeRemoteFavorite`, `ConnectionStore.addManualHost` /
  `removeManualHost`. Because order isn't synced, an applied favorite gets a
  local `sortIndex` from `addRemoteFavorite`'s existing append logic
  (`nextFavoriteSortIndex`) — it lands at the end of this Mac's list.

### 5. Setup, availability, errors

- **Capability:** iCloud with an iCloud-Documents ubiquity container
  (`iCloud.com.lume.Lume`), added to the entitlements file and `project.yml`.
- **iCloud unavailable** (not signed in, capability off): the engine is a
  silent no-op; local favorites and connections work normally — no degraded UI
  dead-ends.
- **Unreadable/corrupt sync doc:** treated as an empty `incoming`; merging
  local with empty keeps all local data (favorites are never lost to a bad
  file), logged via `os.Logger`.
- **Coordination/transfer failure:** retried on the next tick; iCloud's own
  conflict versions are collapsed by the coordinator + the merge.

## Testing

- **`SyncMerge` (pure, the bulk):** LWW picks newer; tombstone deletes;
  tombstone beats a stale re-add; concurrent independent edits both survive;
  30-day prune drops old tombstones; empty-incoming preserves local;
  identity-file tilde rewrite.
- **`FavoritesSyncEngine`:** inject a fake document-store protocol (read/write
  the doc) + the real in-memory `LibraryStore`/`ConnectionStore`, so
  serialize → merge → apply round-trips are tested without iCloud, including
  the `isApplying` feedback-loop guard.
- **Manual checklist (two Macs):** pin on A → appears on B; unpin on A →
  disappears on B; add a manual host on A → connect from B; offline-edit both
  then reconcile; iCloud-signed-out degrades cleanly.

## Non-goals

- Local-file favorite sync (absolute paths don't port across Macs).
- Drag-order / `sortIndex` sync.
- Recents / per-host last-path / GitHub repo-recents sync.
- Syncing the private key, ssh-config hosts, or `gh` auth.
- Instant / real-time push (iCloud propagation is seconds-to-minutes).
- Sharing favorites with other people.
- Any conflict-resolution UI (LWW is automatic and invisible).

## Build order (for the implementation plan)

1. `SyncDocument` Codable types + `SyncMerge` pure three-way merge, with the
   full merge test matrix (no iCloud).
2. A `SyncDocumentStore` protocol (read/write the doc + baseline) with a real
   iCloud/file implementation and a fake for tests.
3. `FavoritesSyncEngine`: read-local projection, apply-to-stores,
   `isApplying` guard; round-trip tests against the fake store.
4. `NSMetadataQuery` observation + NSFileCoordinator wiring + debounced
   triggers.
5. iCloud capability/entitlement + `project.yml`; `AppState` ownership +
   mutation hooks; availability no-op.
6. Manual two-Mac checklist + README note.
