# Token-Budget Surfacing — Design Spec

**Date:** 2026-06-08
**Status:** Approved for planning
**Phase:** 2 of 4 in the "Context Cockpit" roadmap. Builds on Phase 1 (Context Bundles).

## Problem

Phase 1 estimates tokens for a whole copied blob, but nothing tells you **which individual file** is eating the budget. A bloated `CLAUDE.md` hides in a Scan of twenty files. Phase 2 surfaces per-file token weight where files are already listed, so the fat file is obvious.

## Goals

1. A reusable `TokenEstimator` (extracted from Phase 1's inline `chars/4`).
2. **Per-file token badges** in Scan triage rows and BundleView rows.
3. **Sort-by-size** toggle in Scan triage (bloated files float up).
4. A subtle **over-budget tint** on a bundle's total when it's large.

## Non-Goals (v1)

- No standalone "budget dashboard" screen (deferred — user chose badges-only).
- No folder-wide sweep outside an active Scan/Bundle.
- No real tokenizer (the `chars/4` ≈ `bytes/4` heuristic stays).

## Design

### TokenEstimator (LumeKit/Document/TokenEstimator.swift)

```swift
public enum TokenEstimator {
    /// Token estimate for in-memory text: chars ÷ 4 (matches ContextAssembler).
    public static func estimate(_ text: String) -> Int
    /// Fast per-file estimate from on-disk byte size ÷ 4 (NO file read). nil if unavailable.
    public static func estimateFile(_ url: URL) -> Int?
    /// Compact label: "~512", "~1.2k", "~45k"; nil → "—".
    public static func format(_ tokens: Int?) -> String
}
```

- Badges use `estimateFile` (one `stat`, no content read) so a Scan of hundreds of files stays cheap. For ASCII it equals `chars/4`; for multibyte UTF-8 it slightly over-estimates — fine for a "which is bloated" signal, and everything is labeled `~`.
- `ContextAssembler` is refactored to call `TokenEstimator.estimate(text)` instead of its inline expression (DRY; behavior identical, Phase 1 tests stay green).

### Scan triage (ScanTriageView)

- `@State sizes: [String: Int]` populated off-main in `.task(id: app.scanResults)` via `Task.detached` over the paths using `TokenEstimator.estimateFile`.
- `@State sortBySize: Bool`. Displayed rows = `app.scanResults`, or sorted by `sizes[path]` descending when on. The `List` iterates the displayed array; selection/tick logic unchanged.
- Each row gains a trailing token badge (`TokenEstimator.format(sizes[url.path])`), monospaced caption, secondary color.
- Header gains a sort toggle button (`arrow.up.arrow.down`, before Rescan).

### BundleView

- `@State sizes: [String: Int]` populated off-main in `.task(id: bundle?.paths)`.
- Each existing-file row gains the same trailing token badge (before the remove button); missing rows show none.
- Action bar: when `tokenEstimate` exceeds a warn threshold (`100_000`), the `~N tokens` text tints `.orange`. Otherwise unchanged.

## Data Flow

```
file URLs → TokenEstimator.estimateFile (stat, off-main) → [path: tokens] cache → row badges
scan total/sort uses the same cache; bundle total stays ContextAssembler-accurate (unchanged)
```

## Error Handling / Edges

| Case | Behavior |
|------|----------|
| File missing / stat fails | `estimateFile` → nil → badge shows "—". |
| Sort-by-size with missing estimates | nil sorts as 0 (bottom). |
| Empty scan/bundle | no rows, no badges (unchanged). |

## Testing

`TokenEstimatorTests` (Swift Testing):
- `estimate("")==0`, `estimate("abcd")==1`, `estimate("abcde")==2`.
- `estimateFile` of a 40-byte file == 10; missing file → nil.
- `format`: nil→"—", 512→"~512", 1200→"~1.2k", 45000→"~45k".
- Existing `ContextAssembler` token test still passes after the refactor.

UI (ScanTriageView/BundleView badges, sort toggle, tint) verified by build + manual smoke (no unit tests for views, consistent with Phase 1).

## Followups

- Standalone Context Budget dashboard (the deferred Phase 2 "+" option).
- Real tokenizer; configurable threshold.
