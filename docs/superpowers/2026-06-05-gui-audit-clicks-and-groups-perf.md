# Lume GUI Audit — Click Responsiveness & GROUPS Performance

**Date:** 2026-06-05
**Scope:** macOS sidebar interaction model + GROUPS (tag navigator) expand performance
**Status:** Audit only — no code changed. Awaiting review before fixes.
**Reported symptoms:** "clicking in places doesn't do what it has to" · "slow when you open the tag groups"

---

## Executive summary

Both reported problems trace back to **one architectural issue**: each sidebar row stacks
*three competing click mechanisms*, and the sidebar does *global* work on every row
interaction. This isn't a one-line bug — the git history shows this exact area has been
patched 3+ times in a thrash pattern (`2082566` → regression → `a1c306d` → GROUPS layered
on top), which is the classic signature of a wrong interaction model rather than a missing fix.

The good news: the fixes mostly **remove** code.

| # | Symptom | Root cause | Confidence | Risk of fix |
|---|---------|-----------|-----------|-------------|
| 1 | Clicks feel dead / laggy / wrong | Single-tap + double-tap gesture on the same view forces SwiftUI to delay every single click ~250–500ms; manual tap also fights native `List` selection | **High** | Medium (1 runtime unknown) |
| 2 | Slow to open a tag group | (a) variable-view-count `ForEach` re-diffs the whole GROUPS list on expand; (b) every group toggle triggers a full recursive disk-walk of the pinned+browser tree | **High** | Medium |

Baseline `swift build` is green with **zero warnings** (verified 2026-06-05).

---

## Methodology

- Read the live source: `GroupsSection.swift`, `FileTreeView.swift`, `SidebarView.swift`, `AppModel.swift`.
- Cross-checked findings against Apple's SwiftUI List & performance guidance (constant
  view-count rule; invalidation-storm / heavy-body anti-patterns).
- Reviewed `git log` for the sidebar/model to distinguish a fresh bug from an
  architectural thrash.
- Confirmed a green, warning-free baseline build before proposing changes.

---

## Issue 1 — "clicking doesn't do what it should" 🔴

### What's happening

Every row carries **three** overlapping click handlers:

1. **Native `List(selection:)`** — `SidebarView.swift:129` binds the List selection to
   `model.selectedRowIDs`. The List selects a row on mouse-down, for free.
2. **`.onTapGesture(count: 2)`** — double-click to open/drill.
3. **`.onTapGesture { }` (single)** — manually calls `model.clickRow(...)`.

Locations:
- Group header: `GroupsSection.swift:89-99`
- Group file row: `GroupsSection.swift:155-166`
- File/folder row: `FileTreeView.swift:184-208`

### Root cause

**A single-tap recognizer and a double-tap recognizer on the same view are mutually
exclusive — SwiftUI must wait out the double-click interval (~250–500ms) before it can
fire the single-tap.** That enforced wait *is* the "I click and nothing happens." Every
single click in the sidebar pays this latency.

Compounding it: the manual single-tap (`clickRow`) writes `selectedRowIDs` *in addition to*
native `List` selection writing the same property. With ⌘/⇧ the two paths can compute
different sets, so multi-select behaves inconsistently.

### Evidence it's architectural, not a one-off

```
2082566 feat(phaseB): Candidate C — native single-click selection + double-click drill
   …            ← native single-click later stopped delivering (regression)
a1c306d fix(sidebar): restore single-click activation (regression)   ← added the manual count:1 tap
54a649a feat(groups): … pinned single-click selects only
fd207e8 fix(groups): header select-only, selection/expand revalidation …
021b73b fix(groups): wire selection revalidation …
```

The app *originally* used native single-click (the correct macOS pattern). A regression
broke it; the "fix" bolted a manual single-tap on top instead of finding why native
delivery failed — and that manual tap is what now introduces the double-click delay.

### Recommended fix

1. **Delete the manual `.onTapGesture { clickRow(...) }` single handlers** on all three row
   types. Let native `List(selection:)` own single-click selection (instant, on mouse-down,
   with correct ⌘/⇧ semantics and drag-reorder intact).
2. **Keep `.onTapGesture(count: 2)`** for double-click open/drill — with no competing
   single-tap, it no longer delays anything.
3. The existing `.onChange(of: model.selectedRowIDs) { openIfSingleFileSelected() }`
   (`SidebarView.swift:168`) already opens a file when it becomes the sole selection, so
   open-on-single-click keeps working through the native path. Group-header select-only is
   preserved automatically (a header id decodes to `nil`, so nothing opens).

This removes code and returns to the design that worked in `2082566`.

### ⚠️ The one thing to verify at runtime (do not guess)

A code comment (`AppModel.swift:537-544`, `FileTreeView.swift:198-202`) claims native
single-click "was NOT delivering single clicks … the double-click `.onTapGesture` shadowed
it." That may have been caused by an `.accessibilityElement(children: .combine)` that has
since been removed (`FileTreeView.swift:154-160`), or it may still be real.

**Verification step:** apply fix 1–2, build, run, single-click a file → it must select and
open. If native delivery is genuinely still shadowed:

**Fallback (pre-approved):** drop to an AppKit click handler — a small
`NSViewRepresentable` overlay using `NSClickGestureRecognizer` (or `mouseDown` +
`event.clickCount`). AppKit disambiguates single vs double natively with **no SwiftUI
delay** and guaranteed delivery. This is the most robust option for a Finder-style browser
and is the chosen fallback.

---

## Issue 2 — "slow when you open the tag groups" 🔴

Two independent costs fire on every group expand, plus the tap delay from Issue 1.

### Cause 2a — variable-view-count `ForEach` (structural re-diff)

`GroupsSection.swift:22-29`:

```swift
ForEach(tags) { tag in
    groupHeaderRow(tag)                          // 1 view
    if model.expandedGroups.contains(tag.name) { // … +N views when expanded
        ForEach(model.sortedGroupFilePaths(forTagNamed: tag.name), id: \.self) { path in
            groupFileRow(tagName: tag.name, path: path)
        }
    }
}
```

Apple's List rules require a **constant number of views per `ForEach` element**. Here each
`tag` emits 1 view collapsed and 1+N expanded. Changing the per-element view count forces
SwiftUI to re-evaluate the structural identity of the **entire** `ForEach(tags)` on every
expand/collapse — "excessive diffing, broken animations, and potential crashes" per the
guidance.

Same anti-pattern in `FileTreeView.swift:39-56` (row + conditional child subtree per node).

**Fix:** give each element a stable, constant shape. Options, lowest-risk first:
- Wrap each tag's header+children in a single child view (`GroupView(tag:)`) that internally
  renders the header always and the file rows conditionally — the *outer* `ForEach` then has
  a constant 1 view per element.
- Or model rows as a single flattened, pre-computed `[Row]` array (header rows + file rows
  already interleaved) and `ForEach` over that with stable ids — this also makes the rendered
  order and `orderedVisibleRowIDs` share one source of truth.

### Cause 2b — full disk-tree re-walk on every group toggle

`SidebarView.swift:94-109` folds `expandedGroups` *and* the whole `groupFilePaths` /
`displayNames` dictionaries into `rowOrderSignature`; `:173-175` recomputes
`computeOrderedRowIDs()` whenever that signature changes.

`computeOrderedRowIDs()` (`:49-83`) walks the **entire pinned + browser tree** via
`model.children(of:)` per expanded folder. So toggling *one* GROUP — whose membership is
already cached and cheap — forces a synchronous recursive `FileManager` walk of unrelated
favorites and browser subtrees on the main actor.

Additionally, every `SidebarView.body` re-eval reconstructs all mounted `FileTreeView`
structs, and **`FileTreeView.init` calls `model.children(of:)` synchronously**
(`FileTreeView.swift:26-27`) to seed `_children` — another directory read per tree node per
re-render (cache-warm = dict lookups, but still O(visible nodes) of churn).

**Fix:**
- Compute the GROUPS portion of `orderedVisibleRowIDs` from the cache **without** re-walking
  the disk tree. The pinned/browser walk only needs to re-run when *their* structure changes
  — not when a group expands. Split the signature so a group toggle updates only the GROUPS
  slice of the order.
- Shrink `rowOrderSignature`: deep-copying/comparing the full `displayNames` and
  `groupFilePaths` dictionaries on every body pass is itself O(n). Fold them into a cheap
  hash/version counter bumped by `MetaIndexLoader` instead of comparing whole dictionaries.

### Cause 2c — the tap delay (shared with Issue 1)

Expanding a group is a *double-click* on the header (`GroupsSection.swift:89`), so it also
eats the ~300ms disambiguation wait. Fixing Issue 1 removes this regardless.

---

## Broader macOS GUI audit (the "big audit")

Findings beyond the two reported symptoms, roughly by impact:

| Area | Finding | File:line | Suggested action |
|------|---------|-----------|------------------|
| List identity | Variable-view-count `ForEach` (both regions) | `GroupsSection.swift:22-29`, `FileTreeView.swift:39-56` | Constant 1 view/element (see 2a) |
| Hot path | Whole-dict copy+compare in `rowOrderSignature` each body pass | `SidebarView.swift:94-109` | Version counter instead of dict equality |
| Hot path | `FileTreeView.init` does disk read synchronously on every reconstruction | `FileTreeView.swift:26-27` | Confirm cache-warm cost; consider `.task`/seed-once |
| Interaction | Triple click-handling per row | (Issue 1) | Native selection + double-click only |
| Duplication | `visibleChildren` filter logic duplicated across `FileTreeView` and `SidebarView` (flagged in-code as "CROSS-PHASE DRIFT") | `FileTreeView.swift:78-90`, `SidebarView.swift:113-126` | Hoist to one shared helper |
| Correctness | `NSEvent.modifierFlags` read *inside* the tap closure (after the disambiguation delay) can miss a released ⌘/⇧ | `GroupsSection.swift:97-98`, `FileTreeView.swift:206-207` | Moot once native selection handles modifiers; otherwise capture at event time |

**Not problems** (verified good, leave alone): the `MetaIndexLoader` isolation of the
all-metadata `@Query` (`SidebarView.swift:425-459`) is a correct, well-reasoned pattern; the
per-row scalar passing (`displayName`/`isHidden`) is exactly right; off-main debounced editor
writes (`AppModel.swift:441-456`) are sound; the `browseRoot` standardize-didSet guards a real
prior hang.

---

## Proposed fix plan (when you're ready)

Ordered for safe, one-change-at-a-time verification:

1. **Click model (Issue 1).** Remove manual single-tap; keep native selection + double-click.
   Build → run → you confirm clicking. Fall back to AppKit click handler if native delivery
   is still shadowed. *Highest user-visible win; likely also fixes most of the "slow expand"
   feel via 2c.*
2. **GROUPS structural shape (2a).** Extract `GroupView(tag:)` so the outer `ForEach` is
   constant-count. Build → test.
3. **Order recompute scope (2b).** Stop re-walking the disk tree on group toggles; shrink the
   signature. Build → test → you confirm expand speed.
4. **Cleanups** (dedupe `visibleChildren`, modifier-flag capture) — only if still relevant
   after 1–3.

Each step is independently revertible. Logic changes (selection, ordering) are already
covered by `SelectionKit` unit tests; interaction changes need a manual run to confirm.

---

## Appendix — verification artifacts

- Baseline build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
  → exit 0, 0 warnings (2026-06-05).
- Toolchain: Swift 6.3.2, Xcode at `/Applications/Xcode.app`.
