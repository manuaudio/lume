# Diff + Propagate Config — Design Spec

**Date:** 2026-06-08
**Status:** Approved for planning
**Phase:** 3 of 4 in the "Context Cockpit" roadmap. The biggest, stickiest phase.

## Problem

You maintain near-identical `CLAUDE.md` (and `.env` schemas, shared rules) across many projects. When the canonical version evolves, syncing the copies is manual and error-prone. Lume already gathers every `CLAUDE.md` across roots via a **Scan** — so it's the natural place to designate one as canonical, see which copies drift, and push the canonical out.

## Decisions (from brainstorming)

- **Anchor:** a Scan's results (reuse Scans; no new discovery).
- **Apply:** full-file overwrite (copy becomes identical to canonical) after a diff preview + confirm. Hunk-level selective apply is a followup.
- **Persistence:** the canonical choice persists **per Scan** (a model field) — a Scan becomes a durable "sync group."

## Goals

1. A reusable line-diff engine (LumeKit, stdlib `CollectionDifference`, no dependency).
2. Persist a canonical file per Scan.
3. In Scan triage: mark a result canonical; every other result shows a **sync badge** (canonical / same / differs / unreadable).
4. A **DiffView** showing canonical vs a copy (unified, colored).
5. **Overwrite with canonical** (per-file, with confirm + undo) and **Overwrite all differing** (bulk).

## Non-Goals (v1)

- No hunk-level selective apply.
- No three-way / merge; canonical always wins on overwrite.
- No cross-Scan canonical; canonical is scoped to one Scan.
- No diff for binary/unreadable files (shown as unreadable, overwrite disabled).

## Design

### LineDiff (LumeKit/Document/LineDiff.swift) — pure, tested

```swift
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case same, added, removed }
    public let kind: Kind
    public let text: String
}

/// Sync state of a copy relative to the canonical file.
public enum SyncStatus: Sendable { case canonical, same, differs, unreadable }

public enum LineDiff {
    /// Unified line diff old→new. `added` = present in new not old; `removed` = present in old not new.
    public static func compute(from old: String, to new: String) -> [DiffLine]
}
```

`compute` splits both texts on `"\n"`, takes `newLines.difference(from: oldLines)` (stdlib `CollectionDifference`), collects removed old-offsets and inserted new-offsets into sets, then walks both arrays with two cursors: at cursor position emit `.removed` (advance old) if the old offset was removed, else `.added` (advance new) if the new offset was inserted, else `.same` (advance both). This is the canonical CollectionDifference reconstruction and yields correct unified order.

### Scan model (LumeKit/Library/Scan.swift)

Add `public var canonicalPath: String?` (optional → defaults to nil, additive-migration-safe — no property default needed). Thread it through `Scan.init` with default `nil`. `LibraryStore.updateScan` leaves it untouched; add:

```swift
public func setCanonical(_ path: String?, for scan: Scan)  // sets scan.canonicalPath, saves
```

### AppState (Sources/Lume/AppState.swift)

- `var canonicalURL: URL?` — derived from `activeScan?.canonicalPath`.
- `func setCanonical(_ url: URL?)` — `library.setCanonical(url?.path, for: activeScan)`, refresh scans, recompute sync cache.
- `private(set) var syncStatus: [String: SyncStatus]` — for the active scan's results vs canonical, computed **off-main** (read each file + canonical via `TextDocument.load`/`String(contentsOf:)`, compare). Recomputed on `.task` keyed by `(canonicalPath, scanResults)`.
- `var pendingOverwrite: OverwriteRequest?` — drives a confirm dialog. `OverwriteRequest` is `.single(URL)` or `.allDiffering([URL])`.
- `func requestOverwrite(_ target: URL)` / `func requestOverwriteAllDiffering()` — stage the request.
- `func confirmOverwrite()` / `func cancelOverwrite()`.
- `private func overwrite(_ targets: [URL], withCanonical canonical: URL)` — read canonical text once; for each target capture old text, `TextDocument(url: target, text: canonicalText).save()`, `registerUndo("Overwrite with Canonical")` restoring each old text; then recompute sync cache and invalidate the dir cache. Errors → `errorMessage`.

### DiffView (Sources/Lume/Diff/DiffView.swift)

`DiffView(canonical: URL, target: URL)`. In a `.task(id:)` reads both off-main and computes `LineDiff.compute`. Renders lines monospaced: `.removed` red-tinted with `-` gutter, `.added` green-tinted with `+`, `.same` plain with ` `. Scrollable. A header strip shows the two filenames and an **Overwrite with canonical** button → `app.requestOverwrite(target)`.

### ScanTriageView wiring

- **Row context menu:** "Set as Canonical" (non-canonical rows); "Clear Canonical" (the canonical row).
- **Canonical row styling:** anchor/star icon + bold name.
- **Per-row trailing badge:** when `canonicalURL != nil`, show the sync badge (`canonical` / ✓ `same` / Δ `differs` / `·` unreadable) **instead of** the Phase-2 token badge; when no canonical is set, keep the token badge.
- **Preview pane:** when `canonicalURL != nil` and the focused row is a non-canonical existing file, show `DiffView(canonical, focus)` instead of the raw preview; otherwise raw preview as today.
- **Header:** when canonical is set and any row differs, an **Overwrite all differing (N)** button → `app.requestOverwriteAllDiffering()`.
- **Confirm dialog:** `.confirmationDialog` bound to `app.pendingOverwrite != nil` — "Overwrite N file(s) with canonical? This rewrites them on disk." → Overwrite (destructive) / Cancel. Undoable via ⌘Z.

## Data Flow

```
Set canonical → Scan.canonicalPath (persisted) → AppState recomputes syncStatus (off-main reads+compare)
Row badges + preview DiffView read syncStatus / LineDiff
Overwrite → confirm → read canonical once → write each target (TextDocument.save) + registerUndo → recompute syncStatus
```

## Error Handling / Edges

| Case | Behavior |
|------|----------|
| Canonical file missing/unreadable | Treat as no canonical; badges hidden; surface a note. |
| Target unreadable/binary | `SyncStatus.unreadable`; diff shows a notice; overwrite disabled for it. |
| Canonical == focused row | Preview shows raw content (no self-diff); badge says `canonical`. |
| Rescan / canonical no longer in results | Canonical persists on the Scan but if its path isn't in results, no diff anchor; treat as unset until present. |
| Overwrite write fails | `errorMessage`; other targets in a bulk op still attempted. |
| Empty file vs empty file | `.same`. |

## Testing

`LineDiffTests` (Swift Testing):
- Identical texts → all `.same`.
- One added line → that line `.added`, rest `.same`, correct order.
- One removed line → `.removed`.
- A changed line → `.removed` then `.added` for that line.
- Empty↔empty → single `.same` empty line; empty→one line → `.added`.

`LibraryStoreScan`-style test:
- `setCanonical` persists `canonicalPath`; round-trips; `setCanonical(nil)` clears.

UI (DiffView rendering, badges, preview-as-diff, overwrite + undo) verified by build + manual smoke, consistent with Phases 1–2.

## Followups

- Hunk-level selective apply.
- Propagate from a Bundle as well as a Scan.
- Diff against disk for the open editor (reuse DiffView).
