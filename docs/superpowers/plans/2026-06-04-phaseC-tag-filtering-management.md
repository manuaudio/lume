# Phase C — Tag Filtering & Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Pillar ③ of the Professional File Workspace: replace the single-tag sidebar filter with multi-tag **All/Any** filtering (set-based, applied once inside `FileTreeView` so it covers BOTH the FAVORITES and OPEN FOLDER regions automatically), add an active-filter bar (removable chips + All/Any toggle + match count + Clear), and add a **Manage Tags** panel (`TagManagerSheet`) for rename / recolor / merge / delete — backed by new unit-tested `LibraryStore` helpers (`paths(taggedWithAll:)`, `paths(taggedWithAny:)`, `mergeTags(_:into:colorIndex:)`).

**Architecture:** Pure tag/path/set logic lives in `LumeCore` (`LibraryStore`) and is unit-tested against an in-memory `ModelContainer`. SwiftUI surfaces live in `LumeApp/Sidebar` and are verified by `swift build` + a manual checklist (the project has NO UI test target). Filter state lives on `AppModel` as `activeTagFilters: Set<String>` + `tagFilterMatchAll: Bool`. Reuse the already-shipped Phase-1 components — `TagChip`, `TagSwatchPicker`, `TagField`, `TagPalette`, and the existing store ops (`paths(taggedWith:)`, `files(taggedWith:)`, `renameTag` (merges on clash), `recolorTag`, `deleteTag`, `pruneOrphanTags`, `colorIndex(forTagNamed:)`, `allTags`). No schema migration beyond the already-shipped `Tag.colorIndex`.

**Tech Stack:** Swift 6 (Apple Swift 6.3.2, macOS 26 SDK), SwiftUI + SwiftData, Swift Package Manager. macOS app. Swift Testing (`import Testing`, `@Test`, `#expect`) in `Tests/LumeCoreTests/`.

### Cross-Phase Reconciliation (Phase B → Phase C) — READ FIRST

**Phase C runs AFTER Phase B and inherits two collisions Phase B introduces. Both MUST be handled here or the build breaks / the filter silently diverges.**

1. **Duplicated filter logic.** Phase B (`2026-06-04-phaseB-finder-feel-selection.md`, lines ~463–505) adds a flat `orderedRowIDs` to `SidebarView` plus a *private copy* of `FileTreeView.visibleChildren` (named `visibleChildren(of:section:includeHidden:)`) so keyboard nav (⇧↑/⇧↓, ⌘A) walks the same visual order the tree renders. That copy contains its OWN tag-filter clause (`if let tag = model.activeTagFilter { … paths(taggedWith: tag) … }`). When this phase rewrites `FileTreeView.visibleChildren` to set-based filtering, it MUST ALSO rewrite Phase B's duplicated clause in `SidebarView.visibleChildren` to the SAME set-based filter (`model.tagFilteredPaths`). If only one is updated, the rendered tree and the keyboard-nav flat order apply DIFFERENT filtering — keyboard selection jumps to rows that aren't visible (or skips visible ones). They must share a single source of truth: `model.tagFilteredPaths` (Task 3) is that source; both call sites read it.

2. **`activeTagFilter` → `activeTagFilters` rename catches a Phase-B-introduced reference.** Phase B's `orderedRowIDs` copy reads `model.activeTagFilter` (its line ~497) — a NEW reference that did NOT exist when this plan's original 6-site sweep was written (Task 3 lists `AppModel.swift:13`, `SidebarView.swift:197/207/222/223`, `FileTreeView.swift:74`). After Phase B merges there is a 7th site in `SidebarView.visibleChildren`. The rename is therefore NOT complete until that site is migrated too. **Re-grep `activeTagFilter` across `Sources/` AFTER Phase B is merged** (not just against the original sweep) — see Task 4's reconciliation step for the exact command and edit.

This reconciliation is implemented as concrete steps in **Task 4** (filter rewrite + Phase-B `orderedRowIDs` reconciliation) and re-verified in the Self-Review sweep.

**Commands** (the toolchain requires `DEVELOPER_DIR` to be exported, per `tools/build-app.sh` and the existing plans):
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
- Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- Focused tests: `… swift test --filter <TestName>`
- App bundle (manual verification): `tools/build-app.sh` then launch `dist/Lume.app` with `LUME_OPEN_FOLDER=/path` (e.g. `LUME_OPEN_FOLDER=/path open dist/Lume.app`).

---

## File Structure

| File | New/Modified | Responsibility |
|------|--------------|----------------|
| `Sources/LumeCore/Library/LibraryStore.swift` | Modified | Add `paths(taggedWithAll:)`, `paths(taggedWithAny:)`, and `mergeTags(_:into:colorIndex:)`. Pure, testable set math + merge built on existing `paths(taggedWith:)`, `renameTag`, `recolorTag`, `pruneOrphanTags`. |
| `Tests/LumeCoreTests/TagFilterStoreTests.swift` | New | Swift Testing unit tests for the three new store helpers, using the established retained in-memory `ModelContainer` pattern. |
| `Sources/LumeApp/AppModel.swift` | Modified | Replace `activeTagFilter: String?` with `activeTagFilters: Set<String>` + `tagFilterMatchAll: Bool` (default true). Add toggle helpers + an `allowedPaths(...)` deriver. |
| `Sources/LumeApp/Sidebar/FileTreeView.swift` | Modified | Rewrite the `visibleChildren` tag-filter clause to be set-based (intersection for All, union for Any). |
| `Sources/LumeApp/Sidebar/SidebarView.swift` | Modified | Update `tagsSection` to toggle membership in `activeTagFilters`, add a ⚙ Manage control to the Tags section header, present `TagManagerSheet`, and add the active-filter bar (chips + All/Any + count + Clear). **Also (Phase B reconciliation):** rewrite Phase B's duplicated `visibleChildren` (feeding `orderedRowIDs`) to the same set-based filter — see Cross-Phase Reconciliation + Task 4. |
| `Sources/LumeApp/Sidebar/TagManagerSheet.swift` | New | The Manage Tags panel: searchable tag list (recolor swatch, inline rename, file count, multi-select checkbox) + footer actions Merge / Rename / Color / Delete. |

**Out of scope (Phase B owns it; note the dependency only):** the bulk "Tag…" entry point in the multi-select action bar. It already has a working start in `Sources/LumeApp/Sidebar/MultiTagSheet.swift` (driven by `model.editingTagsForSelection`) and does not block this phase.

**Dependency / ordering:** This phase depends on Phase B (`2026-06-04-phaseB-finder-feel-selection.md`) being merged first. Phase B adds `SidebarView.orderedRowIDs` + a private `visibleChildren` copy that (a) duplicates the tag-filter clause this phase rewrites and (b) introduces a 7th `model.activeTagFilter` reference beyond this plan's original 6-site sweep. See **Cross-Phase Reconciliation** above; both are handled concretely in **Task 4**.

---

## Task 1 — Store helper: `paths(taggedWithAll:)` and `paths(taggedWithAny:)` (TDD, real unit tests)

The filter math must be pure and testable. `LibraryStore.paths(taggedWith:)` already returns `Set<String>` for one tag (lines 168–171); these helpers compose it across a set of names.

**Semantics decisions (resolve spec ambiguity):**
- Empty input set ⇒ return empty set. Callers treat "no active filters" as "no filtering" *before* calling, so the store helper itself returning `[]` for empty input is never used as a "show everything" signal (the `FileTreeView` clause is skipped entirely when `activeTagFilters.isEmpty`). This keeps the helper's set algebra unsurprising (`intersection` of zero sets is mathematically "everything", which we deliberately do NOT want from the store).
- A name with no tagged files contributes the empty set: `All` ⇒ result empties; `Any` ⇒ contributes nothing.

**Files:**
- Impl: `Sources/LumeCore/Library/LibraryStore.swift` (add after `paths(taggedWith:)`, currently line 171)
- Test: `Tests/LumeCoreTests/TagFilterStoreTests.swift` (new)

Steps:

- [ ] Create `Tests/LumeCoreTests/TagFilterStoreTests.swift` with the retained-container helper and failing tests for both helpers:
```swift
import Testing
import SwiftData
@testable import LumeCore

// Retain the `ModelContainer` for the whole test body: `LibraryStore` holds only
// a `ModelContext`, and on this toolchain a context whose in-memory container has
// deallocated crashes (SIGTRAP) on the next SwiftData op. Same pattern as
// TagStoreTests / LibraryStoreTests.
@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

// MARK: paths(taggedWithAll:) — intersection

@MainActor @Test func pathsTaggedWithAllIsIntersection() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work", "prod"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["work", "prod", "review"])
    #expect(store.paths(taggedWithAll: ["work", "prod"]) == ["/a.md", "/c.md"])
    #expect(store.paths(taggedWithAll: ["work"]) == ["/a.md", "/b.md", "/c.md"])
    #expect(store.paths(taggedWithAll: ["work", "prod", "review"]) == ["/c.md"])
}

@MainActor @Test func pathsTaggedWithAllEmptyInputIsEmpty() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.paths(taggedWithAll: []) == [])
}

@MainActor @Test func pathsTaggedWithAllWithMissingTagIsEmpty() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    // A name no file carries empties the intersection.
    #expect(store.paths(taggedWithAll: ["work", "ghost"]) == [])
}

// MARK: paths(taggedWithAny:) — union

@MainActor @Test func pathsTaggedWithAnyIsUnion() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["prod"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["review"])
    #expect(store.paths(taggedWithAny: ["work", "prod"]) == ["/a.md", "/b.md"])
    #expect(store.paths(taggedWithAny: ["work", "prod", "review"]) == ["/a.md", "/b.md", "/c.md"])
}

@MainActor @Test func pathsTaggedWithAnyEmptyInputIsEmpty() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.paths(taggedWithAny: []) == [])
}

@MainActor @Test func pathsTaggedWithAnyIgnoresMissingTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])
    #expect(store.paths(taggedWithAny: ["work", "ghost"]) == ["/a.md"])
}
```
- [ ] Run the new tests and confirm they FAIL to compile / fail (methods don't exist yet): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TaggedWith`
- [ ] Add the two helpers to `LibraryStore.swift`, immediately after `paths(taggedWith:)` (currently ending line 171):
```swift
    /// Paths carrying EVERY one of `names` (set intersection) — the All/AND
    /// filter. Empty input returns the empty set (callers skip filtering when
    /// there are no active filters, so we never need "intersection of zero sets =
    /// everything"). A name no file carries empties the result.
    public func paths(taggedWithAll names: Set<String>) -> Set<String> {
        guard let first = names.first else { return [] }
        var result = paths(taggedWith: first)
        for name in names.dropFirst() {
            result.formIntersection(paths(taggedWith: name))
            if result.isEmpty { break }
        }
        return result
    }

    /// Paths carrying ANY of `names` (set union) — the Any/OR filter. Empty input
    /// returns the empty set. Missing names contribute nothing.
    public func paths(taggedWithAny names: Set<String>) -> Set<String> {
        var result = Set<String>()
        for name in names { result.formUnion(paths(taggedWith: name)) }
        return result
    }
```
- [ ] Run the tests and confirm they PASS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TaggedWith`
- [ ] Commit: `git commit -m "Add paths(taggedWithAll:) / paths(taggedWithAny:) set helpers"`

---

## Task 2 — Store helper: `mergeTags(_:into:colorIndex:)` (TDD, real unit tests)

Merge several tags into one survivor: re-point every file off the others onto the survivor, apply the chosen color, and prune the emptied tags. Build on the existing `renameTag(named:to:)` (which already merges on a name clash, lines 226–247) and `recolorTag` / `pruneOrphanTags`.

**Semantics decisions (resolve spec ambiguity):**
- `survivor` may or may not already exist. If it doesn't yet exist but appears in `names`, the first matching source is renamed to it (via `renameTag`'s rename branch), then the rest merge onto it.
- Names equal to `survivor` are skipped as sources (you can't merge a tag into itself).
- A nil `colorIndex` leaves the survivor's existing color; a non-nil one recolors it after the merge.
- Unknown / already-absent names are no-ops. The survivor ends up carrying the union of all source files (de-duped — `renameTag`'s merge branch already de-dups per file). Emptied source tags are deleted by `renameTag`'s merge branch; a final `pruneOrphanTags()` guarantees no stragglers.
- Returns `Bool`: `true` if the survivor exists after the operation.

**Files:**
- Impl: `Sources/LumeCore/Library/LibraryStore.swift` (add after `renameTag`, currently ending line 247)
- Test: `Tests/LumeCoreTests/TagFilterStoreTests.swift` (append)

Steps:

- [ ] Append failing merge tests to `Tests/LumeCoreTests/TagFilterStoreTests.swift`:
```swift
// MARK: mergeTags(_:into:colorIndex:)

@MainActor @Test func mergeTagsConsolidatesFilesOntoSurvivor() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["wip", "draft", "keep"])
    let ok = store.mergeTags(["wip", "draft"], into: "wip", colorIndex: nil)
    #expect(ok == true)
    // "draft" is gone, "wip" carries every file that had wip OR draft.
    #expect(store.allTags().map(\.name).sorted() == ["keep", "wip"])
    #expect(store.paths(taggedWith: "wip") == ["/a.md", "/b.md", "/c.md"])
    // De-duped: /c.md had both, ends with a single wip (+ keep).
    #expect(store.meta(for: "/c.md")?.tags.map(\.name).sorted() == ["keep", "wip"])
}

@MainActor @Test func mergeTagsAppliesChosenColor() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    let ok = store.mergeTags(["wip", "draft"], into: "wip", colorIndex: 5)
    #expect(ok == true)
    #expect(store.colorIndex(forTagNamed: "wip") == 5)
}

@MainActor @Test func mergeTagsIntoBrandNewSurvivorName() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    // Survivor name isn't an existing tag — first source is renamed to it.
    let ok = store.mergeTags(["wip", "draft"], into: "status", colorIndex: 3)
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["status"])
    #expect(store.paths(taggedWith: "status") == ["/a.md", "/b.md"])
    #expect(store.colorIndex(forTagNamed: "status") == 3)
}

@MainActor @Test func mergeTagsSkipsSurvivorAsSourceAndUnknowns() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    // "wip" appears as both survivor and source (skip-self); "ghost" is unknown.
    let ok = store.mergeTags(["wip", "draft", "ghost"], into: "wip", colorIndex: nil)
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["wip"])
    #expect(store.paths(taggedWith: "wip") == ["/a.md", "/b.md"])
}

@MainActor @Test func mergeTagsPrunesEmptiedTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["draft"])
    _ = store.mergeTags(["wip", "draft"], into: "wip", colorIndex: nil)
    // No orphan "draft" tag lingers in the sidebar vocabulary.
    #expect(store.files(taggedWith: "draft").isEmpty)
    #expect(store.allTags().contains { $0.name == "draft" } == false)
}
```
- [ ] Run and confirm FAIL: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter mergeTags`
- [ ] Add `mergeTags` to `LibraryStore.swift`, immediately after `renameTag` (currently ending line 247):
```swift
    /// Merge several tags into one. Every file on a source tag is re-pointed onto
    /// `survivor` (de-duped), the chosen `colorIndex` (if any) is applied, and the
    /// emptied source tags are pruned. Built on `renameTag` (which already merges
    /// on a name clash) so the per-file de-dup logic lives in exactly one place.
    /// `survivor` need not pre-exist: the first matching source is renamed to it.
    /// Returns true if the survivor exists after the operation.
    @discardableResult
    public func mergeTags(_ names: [String], into survivor: String, colorIndex: Int?) -> Bool {
        // Fold every other named tag onto the survivor. `renameTag` renames when
        // the survivor is absent and merges when it already exists, so iterating
        // sources naturally creates-then-merges.
        for name in names where name != survivor {
            _ = renameTag(named: name, to: survivor)
        }
        if let colorIndex { recolorTag(named: survivor, colorIndex: colorIndex) }
        pruneOrphanTags()
        return existingTag(named: survivor) != nil
    }
```
- [ ] Run and confirm PASS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter mergeTags`
- [ ] Run the full suite to confirm no regressions: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] Commit: `git commit -m "Add LibraryStore.mergeTags(_:into:colorIndex:) with unit tests"`

---

## Task 3 — `AppModel` filter-state migration: `activeTagFilter` → `activeTagFilters` + `tagFilterMatchAll`

Replace the single-tag filter with a multi-tag set + an All/Any flag, and add small helpers so the UI and `FileTreeView` don't re-derive the math. `activeTagFilter` is referenced at exactly these sites (all updated in this plan):
- `Sources/LumeApp/AppModel.swift:13` (declaration)
- `Sources/LumeApp/Sidebar/SidebarView.swift:197, 207, 222, 223` (Tags section)
- `Sources/LumeApp/Sidebar/FileTreeView.swift:74` (filter application)

This is NOT persisted (the old one wasn't either) — it's session-scoped, so no `UserDefaults` migration is needed.

**Files:**
- `Sources/LumeApp/AppModel.swift:13`
- "Test": `swift build` compiles (this task only changes state; the call sites are fixed in Tasks 4–6 in the same working tree before the build is expected to pass — sequence the build check at the end of Task 4).

Steps:

- [ ] In `AppModel.swift`, replace the declaration on line 13:
```swift
    var activeTagFilter: String?
```
with:
```swift
    /// Active tag filter (multi-tag). Empty ⇒ no filtering. Membership is toggled
    /// from the sidebar Tags section and the active-filter bar.
    var activeTagFilters: Set<String> = []
    /// true = All/AND (intersection), false = Any/OR (union). Defaults to All.
    var tagFilterMatchAll: Bool = true
```
- [ ] Add filter helpers to `AppModel` (place them near `drillInto`, after the Browser drill section ~line 158, or anywhere in the type). They centralize the toggle + the allowed-paths math so both the sidebar and `FileTreeView` call one source of truth:
```swift
    // MARK: - Tag filtering

    /// True when any tag filter is active.
    var hasTagFilter: Bool { !activeTagFilters.isEmpty }

    /// Toggle a tag's membership in the active filter set.
    func toggleTagFilter(_ name: String) {
        if activeTagFilters.contains(name) { activeTagFilters.remove(name) }
        else { activeTagFilters.insert(name) }
    }

    /// Remove a tag from the active filter set (active-filter bar ✕).
    func removeTagFilter(_ name: String) { activeTagFilters.remove(name) }

    /// Clear all active tag filters.
    func clearTagFilters() { activeTagFilters.removeAll() }

    /// The set of paths allowed by the current filter, or nil when no filter is
    /// active (nil ⇒ "show everything", so callers skip filtering). Uses the
    /// store's tested set helpers — All ⇒ intersection, Any ⇒ union.
    var tagFilteredPaths: Set<String>? {
        guard hasTagFilter, let store else { return nil }
        return tagFilterMatchAll
            ? store.paths(taggedWithAll: activeTagFilters)
            : store.paths(taggedWithAny: activeTagFilters)
    }
```
- [ ] (Build deferred to Task 4 — call sites are still on the old API until then.)

---

## Task 4 — `FileTreeView.visibleChildren`: set-based filter rewrite (+ Phase B reconciliation)

Rewrite the tag-filter clause (currently lines 74–78) to use `model.tagFilteredPaths`. Filtering already runs inside `FileTreeView`, so this single change covers BOTH the FAVORITES and OPEN FOLDER regions in the *rendered tree*. **However**, Phase B (merged before this phase) added a SECOND, duplicated `visibleChildren` inside `SidebarView` that feeds `orderedRowIDs` (the flat keyboard-nav order). That copy has its own tag-filter clause reading the old `model.activeTagFilter`. This task rewrites BOTH copies to the same set-based filter so the keyboard order and the rendered tree stay identical (see Cross-Phase Reconciliation). Directories are kept (so you can still navigate into them) exactly as today.

**Files:**
- `Sources/LumeApp/Sidebar/FileTreeView.swift:74-78` (rendered tree filter)
- `Sources/LumeApp/Sidebar/SidebarView.swift` (Phase B's `visibleChildren` copy, ~line 497 after Phase B merges — feeds `orderedRowIDs`)
- "Test": `swift build` compiles + manual checklist below.

Steps:

- [ ] In `FileTreeView.swift`, replace the current clause (lines 74–78):
```swift
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            // Keep directories (so you can navigate into them) + tagged files.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
```
with:
```swift
        if let allowed = model.tagFilteredPaths {
            // Set-based filter: `allowed` is the intersection (All) or union (Any)
            // of the active tags' paths. Keep directories (so you can navigate
            // into them) + files in the allowed set. Covers BOTH regions since
            // filtering lives here.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
```
- [ ] **Phase B reconciliation — re-grep AFTER Phase B is merged.** The original sweep in Task 3 lists 6 sites; Phase B added a 7th in `SidebarView.visibleChildren`. Confirm the real current set of references (do NOT rely on the hard-coded line numbers above):
```bash
grep -rn "activeTagFilter\b" /Users/manu/Developer/lume/Sources/
```
  Expect a hit inside `SidebarView.swift`'s Phase-B `visibleChildren` copy (the `if let tag = model.activeTagFilter { … paths(taggedWith: tag) … }` clause feeding `orderedRowIDs`), in addition to the sites already enumerated. Every hit must be migrated before the build is clean.
- [ ] **Reconcile Phase B's duplicated filter clause** in `SidebarView.visibleChildren` (the private copy that feeds `orderedRowIDs`). Find the clause Phase B added:
```swift
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
```
  and replace it with the SAME set-based filter the rendered tree uses, so the keyboard-nav flat order and the tree share one source of truth (`model.tagFilteredPaths`):
```swift
        if let allowed = model.tagFilteredPaths {
            // Shared filter source of truth with FileTreeView.visibleChildren:
            // keep the keyboard-nav flat order (orderedRowIDs) identical to the
            // rendered tree. All ⇒ intersection, Any ⇒ union; directories kept.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
```
  (If a later refactor hoists this filter into a single shared helper, even better — but at minimum both clauses must read `model.tagFilteredPaths`.)
- [ ] Build (the Tags-section + filter-bar call sites in `SidebarView` are still on the old single-filter API until Task 5, so expect compile errors in `SidebarView.swift` for THOSE sites only — fixed in Task 5; the Phase-B `visibleChildren` clause above is already migrated): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` (expected: only `SidebarView.swift` errors about `activeTagFilter` from the Task-5 sites, none from `visibleChildren`/`orderedRowIDs`).

---

## Task 5 — `SidebarView`: Tags section toggle + ⚙ Manage control + active-filter bar

Three changes to `SidebarView.swift`:
1. `tagsSection` (lines 194–235): tag rows now reflect set membership and toggle it; the section gains a header with a ⚙ **Manage** button that presents `TagManagerSheet`.
2. The Delete context-menu action (lines 221–226) clears the tag from `activeTagFilters` instead of the old single filter.
3. Add an **active-filter bar** at the top of the sidebar (chips + All/Any toggle + match count + Clear), shown only when a filter is active.

**Files:**
- `Sources/LumeApp/Sidebar/SidebarView.swift` (lines 17 area for new `@State`, 194–235 `tagsSection`, ~52–53 for the bar inset)
- "Test": `swift build` compiles + manual checklist.

Steps:

- [ ] Add `@State` for the manager sheet next to `renamingTag` (after line 17):
```swift
    /// Drives the Manage Tags panel.
    @State private var showingTagManager = false
```
- [ ] Replace the whole `tagsSection` (lines 194–235) with the set-membership version plus a header ⚙ Manage control and the manager sheet. **Header form change:** the existing section uses the string-header form `Section("Tags") { … }`. To fit the ⚙ Manage button alongside the title, this CONVERTS it to the trailing-closure header form `Section { … } header: { HStack { Text("TAGS"); Spacer(); Button … } }`. The string-header form can't host a button, so the form change is required — that's why the header looks different below.
```swift
    @ViewBuilder private var tagsSection: some View {
        Section {
            ForEach(tags) { tag in
                let active = model.activeTagFilters.contains(tag.name)
                HStack(spacing: 6) {
                    Image(systemName: active ? "tag.fill" : "tag")
                        .foregroundStyle(tagColor(tag.colorIndex))
                    Text(tag.name)
                        .foregroundStyle(active ? Color.primary : .secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.toggleTagFilter(tag.name)
                }
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") {
                        renamingTag = TagRef(name: tag.name)
                    }
                    Menu("Color") {
                        ForEach(0..<TagPalette.count, id: \.self) { i in
                            Button(TagPalette.swatch(at: i).name) {
                                model.store?.recolorTag(named: tag.name, colorIndex: i)
                            }
                        }
                    }
                    Divider()
                    Button("Delete Tag", systemImage: "trash", role: .destructive) {
                        model.removeTagFilter(tag.name)
                        model.store?.deleteTag(named: tag.name)
                    }
                }
            }
        } header: {
            HStack {
                Text("TAGS")
                Spacer()
                Button { showingTagManager = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Manage tags (rename, recolor, merge, delete)")
            }
        }
        .sheet(item: $renamingTag) { ref in
            TagRenameSheet(model: model, oldName: ref.name) {
                renamingTag = nil
            }
        }
        .sheet(isPresented: $showingTagManager) {
            TagManagerSheet(model: model, isPresented: $showingTagManager)
        }
    }
```
- [ ] Add the **active-filter bar** as a top safe-area inset. In `body` (lines 47–53), the List currently has `.safeAreaInset(edge: .top) { topBar }`. Insert the filter bar BELOW the top bar so it sits between the filter field and the list. Change line 53 region to:
```swift
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                topBar
                if model.hasTagFilter { activeFilterBar }
            }
        }
```
- [ ] Add the `activeFilterBar` view (place near `topBar`, after line 117). It shows removable chips (reusing `TagChip` with `onRemove`), an All/Any toggle, a live match count, and Clear. The match count counts files (directories are navigational, not "matches") in the allowed set. **Reactivity note:** `model.tagFilteredPaths.count` re-renders when `activeTagFilters` or `tagFilterMatchAll` change (both are observed `@Observable` state), but it does NOT re-render in response to live file-tag mutations made elsewhere while the bar is open (the count isn't recomputed on every SwiftData change). This is acceptable for the stated behaviors — the count reflects the filter selection, and tag membership rarely changes underneath an open filter bar; it refreshes the next time a filter toggles.
```swift
    /// Active tag-filter bar: removable chips + All/Any toggle + match count +
    /// Clear. Only rendered when `model.hasTagFilter`.
    private var activeFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { model.tagFilterMatchAll },
                                              set: { model.tagFilterMatchAll = $0 })) {
                    Text("All").tag(true)
                    Text("Any").tag(false)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .help("All = match every tag (AND); Any = match any tag (OR)")
                Spacer(minLength: 0)
                Text("\(model.tagFilteredPaths?.count ?? 0) match\(model.tagFilteredPaths?.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") { model.clearTagFilters() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            FlowLayout(spacing: 4) {
                ForEach(Array(model.activeTagFilters).sorted(), id: \.self) { name in
                    TagChip(name: name,
                            colorIndex: model.store?.colorIndex(forTagNamed: name) ?? 0,
                            onRemove: { model.removeTagFilter(name) })
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
```
- [ ] Build (will still fail until `TagManagerSheet` exists — that's Task 6; this confirms the `activeTagFilter` references are gone and only the missing-type error remains): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` (expected: only `cannot find 'TagManagerSheet' in scope`).

---

## Task 6 — New `TagManagerSheet.swift`: Manage Tags panel

The Manage Tags panel: searchable list of all tags; each row shows a recolor swatch (`TagSwatchPicker` in a popover), the name (inline rename committed via `renameTag`), the file count, and a multi-select checkbox. Footer actions on the checkbox selection: **Merge** (2+ → choose survivor name + color via a small inline merge step), **Rename** (exactly 1), **Color** (1+), **Delete** (1+). Opened from the ⚙ Manage control added in Task 5.

**Decisions (resolve spec ambiguity):**
- Reactive: `@Query private var allTags: [Tag]` drives the list (live counts/colors), filtered by a search string.
- Selection: `Set<String>` of tag names (checkbox membership). Footer buttons enable/disable by count.
- Merge: pressing **Merge** with 2+ selected reveals an inline merge composer (survivor name `TextField` pre-filled with the first selected name, a `TagSwatchPicker` for the color) and a confirm button calling `store.mergeTags(selected, into: survivor, colorIndex:)`. Simpler than a nested sheet and avoids sheet-over-sheet on macOS.
- Rename: enabled for exactly one selection; reuses the existing `TagRenameSheet` via a `TagRef`.
- Color: a `TagSwatchPicker` popover that recolors every selected tag.
- Delete: deletes every selected tag via `store.deleteTag(named:)`.
- After any mutation, drop now-stale names from `selection` and from `model.activeTagFilters` (a renamed/merged/deleted tag shouldn't linger as an active filter).
- **Mutation routing (audit fix):** ALL writes (recolor / rename / merge / delete) go through `model.store` — NOT a sheet-local `LibraryStore(context: <environment modelContext>)`. The sidebar's `@Query(sort: \Tag.name) tags` and every other app mutation use `model.store` (built from `AppModel.libraryContext`). Using a different `ModelContext` for the sheet could leave the sidebar `@Query` stale and risk save conflicts. The sheet therefore takes `model: AppModel` (already in its signature) and exposes `private var store: LibraryStore? { model.store }`. The read-only `@Query` keeps observing the environment container for live display, which is correct because `ContentView` assigns `model.libraryContext = context` (the same instance), but the routing stays correct even if that wiring later diverges.

**Files:**
- New: `Sources/LumeApp/Sidebar/TagManagerSheet.swift`
- "Test": `swift build` compiles + manual checklist.

Steps:

- [ ] Create `Sources/LumeApp/Sidebar/TagManagerSheet.swift`:
```swift
import SwiftUI
import SwiftData
import LumeCore

/// The Manage Tags panel (Pillar ③). Curate the tag *vocabulary*: recolor,
/// inline-rename, multi-select, and Merge / Rename / Color / Delete from a
/// footer. Reuses `TagChip`/`TagSwatchPicker` and the tested `LibraryStore` ops
/// (`renameTag`, `recolorTag`, `deleteTag`, `mergeTags`). Opened from the ⚙ in
/// the sidebar Tags header.
struct TagManagerSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool

    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var search = ""
    /// Checkbox selection — tag names.
    @State private var selection: Set<String> = []
    /// Drives the single-tag rename sheet.
    @State private var renaming: TagRef?
    /// Drives the bulk color popover.
    @State private var pickingColor = false
    /// Drives the inline merge composer.
    @State private var merging = false
    @State private var mergeSurvivor = ""
    @State private var mergeColorIndex = 0

    // Route ALL mutations through `model.store` (built from `AppModel.libraryContext`),
    // NOT a fresh `LibraryStore(context: <environment modelContext>)`. The rest of
    // the app — including the sidebar's `@Query(sort: \Tag.name) tags` — mutates
    // through `model.store`. If the environment `modelContext` and
    // `AppModel.libraryContext` were ever distinct `ModelContext` instances, a
    // sheet-local store would write to a different context: recolor/rename/merge/
    // delete would NOT propagate to the sidebar's `@Query`, and you could hit save
    // conflicts. (`ContentView` does `model.libraryContext = context`, so today
    // they are the same instance — but this routing keeps it correct even if that
    // wiring changes.) The `@Query` above still observes the environment container,
    // which is fine for read-only display; writes go through `store` below.
    private var store: LibraryStore? { model.store }

    private var filtered: [Tag] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var selectedNames: [String] { selection.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            if merging { mergeComposer } else { footer }
        }
        .frame(width: 420, height: 460)
        .sheet(item: $renaming) { ref in
            TagRenameSheet(model: model, oldName: ref.name) {
                // Drop the old name from selection/filters; the renamed/merged
                // tag may not match the old name anymore.
                selection.remove(ref.name)
                model.removeTagFilter(ref.name)
                renaming = nil
            }
        }
    }

    // MARK: Header (title + search + Done)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Manage Tags").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search tags…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .padding(16)
    }

    // MARK: List of tags

    private var list: some View {
        List {
            ForEach(filtered) { tag in
                row(for: tag)
            }
        }
        .listStyle(.inset)
    }

    private func row(for tag: Tag) -> some View {
        let name = tag.name
        let isOn = selection.contains(name)
        let count = store?.files(taggedWith: name).count ?? 0
        return HStack(spacing: 10) {
            Button {
                if isOn { selection.remove(name) } else { selection.insert(name) }
            } label: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            swatchButton(for: name, colorIndex: tag.colorIndex)

            // Inline rename committed on submit/blur. Routes through `model.store`.
            InlineTagName(name: name, store: store) { old in
                selection.remove(old)
                model.removeTagFilter(old)
            }

            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// A color swatch dot that opens a recolor popover for one tag.
    private func swatchButton(for name: String, colorIndex: Int) -> some View {
        SingleSwatch(name: name, colorIndex: colorIndex, store: store)
    }
    // NOTE: `store` is `LibraryStore?` (it is `model.store`). `SingleSwatch` and
    // `InlineTagName` take an optional store and no-op when it is nil.

    // MARK: Footer (Merge / Rename / Color / Delete)

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Merge…") { beginMerge() }
                .disabled(selection.count < 2)
            Button("Rename…") {
                if let only = selectedNames.first, selection.count == 1 {
                    renaming = TagRef(name: only)
                }
            }
            .disabled(selection.count != 1)
            Button("Color") { pickingColor = true }
                .disabled(selection.isEmpty)
                .popover(isPresented: $pickingColor, arrowEdge: .top) {
                    TagSwatchPicker(current: 0) { idx in
                        for n in selectedNames { store?.recolorTag(named: n, colorIndex: idx) }
                        pickingColor = false
                    }
                }
            Button("Delete", role: .destructive) {
                for n in selectedNames {
                    model.removeTagFilter(n)
                    store?.deleteTag(named: n)
                }
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
        }
        .padding(16)
    }

    // MARK: Merge composer (survivor name + color)

    private func beginMerge() {
        mergeSurvivor = selectedNames.first ?? ""
        mergeColorIndex = store?.colorIndex(forTagNamed: mergeSurvivor) ?? 0
        merging = true
    }

    private var mergeComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge \(selection.count) tags").font(.subheadline.bold())
            HStack(spacing: 8) {
                Text("Into:").foregroundStyle(.secondary)
                TextField("Survivor name", text: $mergeSurvivor)
                    .textFieldStyle(.roundedBorder)
            }
            TagSwatchPicker(current: mergeColorIndex) { mergeColorIndex = $0 }
            HStack {
                Spacer()
                Button("Cancel") { merging = false }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    let survivor = mergeSurvivor.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !survivor.isEmpty else { return }
                    let names = selectedNames
                    store?.mergeTags(names, into: survivor, colorIndex: mergeColorIndex)
                    // Re-point any active filters off merged names onto survivor.
                    for n in names where n != survivor { model.removeTagFilter(n) }
                    selection = [survivor]
                    merging = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mergeSurvivor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

/// A single recolor swatch dot (one tag) with a popover picker. `store` is
/// optional (it is `model.store`); a nil store no-ops the recolor.
private struct SingleSwatch: View {
    let name: String
    let colorIndex: Int
    let store: LibraryStore?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Circle().fill(tagColor(colorIndex)).frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help("Change color")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            TagSwatchPicker(current: colorIndex) { idx in
                store?.recolorTag(named: name, colorIndex: idx)
                picking = false
            }
        }
    }
}

/// Inline tag-name editor. Commits on submit/blur via `renameTag` (which merges
/// on a name clash). `onRenamed(oldName)` lets the parent prune stale selection.
/// `store` is optional (it is `model.store`); a nil store no-ops the rename.
private struct InlineTagName: View {
    let name: String
    let store: LibraryStore?
    let onRenamed: (String) -> Void

    @State private var text = ""
    @State private var didInit = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tag name", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { if !didInit { text = name; didInit = true } }
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { text = name; return }
        if store?.renameTag(named: name, to: trimmed) == true {
            onRenamed(name)
        } else {
            text = name   // rejected (or no store) — restore
        }
    }
}
```
- [ ] Build the whole package: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` (expected: clean compile).
- [ ] Run the full test suite (regression guard — existing tag/copy-paths/hidden/favorite tests must stay green): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] Build the app bundle for manual verification: `tools/build-app.sh`
- [ ] **Manual verification checklist** (launch with a tagged folder, e.g. `LUME_OPEN_FOLDER=/path open dist/Lume.app`):
  - [ ] Click a tag in the Tags section → it highlights (`tag.fill`), the active-filter bar appears, the tree filters to matching files (folders remain), and the match count is correct.
  - [ ] Click a second tag → with **All** selected, the tree narrows to files carrying BOTH; switch to **Any** → it widens to files carrying EITHER; the count updates each way.
  - [ ] The chips in the bar are removable (✕) and removing the last one hides the bar and shows the full tree. **Clear** empties all at once.
  - [ ] Filtering applies in BOTH the FAVORITES (expand a pinned folder) and OPEN FOLDER regions with no extra wiring.
  - [ ] Click ⚙ in the Tags header → `TagManagerSheet` opens; search narrows the list; each row shows the swatch, an editable name, the file count, and a checkbox.
  - [ ] Inline-rename a tag (edit name, press Return) → renames; renaming onto an existing name merges (file count reflects the union).
  - [ ] Recolor a tag via its swatch dot → color updates live in the sheet, the sidebar, and any active chips.
  - [ ] Select 2+ tags → **Merge…** → set survivor name + color → Merge consolidates files onto the survivor, deletes the others, and they vanish from the list and sidebar.
  - [ ] Select 1 tag → **Rename…**; select 1+ → **Color**; select 1+ → **Delete** removes them (and they drop out of any active filter).
- [ ] Commit: `git commit -m "Add multi-tag filter bar + TagManagerSheet (Pillar 3)"`

---

## Self-Review

**Every Pillar ③ spec requirement → a task:**

| Spec requirement (Pillar ③) | Task |
|---|---|
| Replace `activeTagFilter: String?` with `activeTagFilters: Set<String>` + `tagFilterMatchAll: Bool` (default true) | Task 3 |
| Set-based filter in `FileTreeView.visibleChildren` (intersection=All, union=Any) covering both regions | Task 4 |
| Helpers `paths(taggedWithAll:)` / `paths(taggedWithAny:)` on `LibraryStore`, unit-tested | Task 1 |
| Active filter bar: removable chips + All/Any toggle + match count + Clear | Task 5 |
| Clicking a Tags-section tag toggles membership in `activeTagFilters` | Task 5 |
| `TagManagerSheet` (new file), opened from a ⚙ Manage control in the Tags header | Tasks 5 (control) + 6 (sheet) |
| Searchable list; per-row swatch recolor, inline rename, file count, multi-select checkbox | Task 6 |
| Footer: Merge / Rename / Color / Delete | Task 6 |
| `mergeTags(_:into:colorIndex:)` (re-point files, apply color, prune emptied), unit-tested | Task 2 |
| Reuse Phase-1 components (`TagChip`, `TagSwatchPicker`, `TagField`, `TagRenameSheet`, store ops) | Tasks 5, 6 |
| No schema migration beyond shipped `Tag.colorIndex` | Confirmed — no `@Model` changes anywhere in this plan |
| Unit tests in `Tests/LumeCoreTests/` with retained in-memory `ModelContainer` | Tasks 1, 2 (`TagFilterStoreTests.swift`) |
| Regression guard: existing tests stay green | Task 2 + Task 6 full-suite runs |

**Placeholder scan:** No `TODO`, `FIXME`, `...`, or stubbed bodies. Every code block is complete and uses real signatures.

**Type / signature consistency (new store methods ↔ call sites):**
- `paths(taggedWithAll names: Set<String>) -> Set<String>` — called as `store.paths(taggedWithAll: activeTagFilters)` in `AppModel.tagFilteredPaths` (Task 3); `activeTagFilters` is `Set<String>` ✓.
- `paths(taggedWithAny names: Set<String>) -> Set<String>` — called as `store.paths(taggedWithAny: activeTagFilters)` ✓.
- `mergeTags(_ names: [String], into survivor: String, colorIndex: Int?) -> Bool` — called as `store.mergeTags(names, into: survivor, colorIndex: mergeColorIndex)` (`names: [String]` from `selectedNames`, `mergeColorIndex: Int`) ✓.
- `model.tagFilteredPaths: Set<String>?` returns nil when no filter → `FileTreeView` `if let allowed = model.tagFilteredPaths` skips filtering ✓; `activeFilterBar` reads `.count` only inside `model.hasTagFilter` ✓.
- Reused existing signatures (verified against source): `paths(taggedWith name: String) -> Set<String>`, `files(taggedWith name: String) -> [FileMeta]`, `renameTag(named:to:) -> Bool` (merges on clash), `recolorTag(named:colorIndex:)`, `deleteTag(named:)`, `pruneOrphanTags() -> Int`, `colorIndex(forTagNamed:) -> Int`, `allTags() -> [Tag]`, `existingTag(named:)` (private — only used inside `mergeTags`, same type) ✓.
- Reused UI signatures: `TagChip(name:colorIndex:onRemove:onRecolor:)`, `TagSwatchPicker(current:onPick:)`, `TagRenameSheet(model:oldName:onClose:)`, `TagRef(name:)`, `FlowLayout(spacing:)`, `tagColor(_:) -> Color` ✓.

**`activeTagFilter` reference sweep (all migrated):** `AppModel.swift:13` (Task 3), `SidebarView.swift:197, 207, 222, 223` (Task 5), `FileTreeView.swift:74` (Task 4), **plus the Phase-B-introduced 7th site in `SidebarView.visibleChildren` (~line 497) feeding `orderedRowIDs` — migrated in Task 4's reconciliation step**. Because Phase B ADDS a reference not present in the original sweep, the grep MUST be re-run against the live `Sources/` AFTER Phase B merges, not against the hard-coded list. After Task 6, `grep -rn "activeTagFilter\b" Sources` must return zero hits (the new symbol is `activeTagFilters`).

**Phase boundary:** The bulk "Tag…" action-bar entry point is Phase B's (it already starts from `MultiTagSheet` via `model.editingTagsForSelection`); this plan does not touch it. Filtering in the *rendered tree* is implemented once in `FileTreeView` and is therefore region-agnostic. The ONE other place the same filter must be applied is Phase B's `SidebarView.visibleChildren` copy feeding `orderedRowIDs` (keyboard-nav flat order); Task 4 rewrites BOTH to read `model.tagFilteredPaths` so they never diverge (see Cross-Phase Reconciliation).
