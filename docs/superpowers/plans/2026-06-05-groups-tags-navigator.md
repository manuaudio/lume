# GROUPS — Tag-Driven Navigator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GROUPS sidebar region that renders every tag as an expandable, color-tinted virtual folder whose contents are every file carrying that tag (from anywhere on disk), replacing the old tag-filter UI.

**Architecture:** Tags already model a many-to-many `Tag ⇄ FileMeta` relationship. GROUPS is a pure presentation layer on top of it: a flat list of tags, each expandable to show its files sorted by effective display name. The row-id grammar (`SidebarRow`) is extended so the same file under two groups gets two distinct, decodable ids. Selection math (`RowSelection`) is untouched (it operates on opaque string ids). The store stops auto-pruning orphan tags so empty groups persist, and gains two new operations (create-empty-tag, untag-single). The old `activeTagFilters` state, the TAGS filter section, the active-filter bar, and `tagFilteredPaths` threading are removed entirely.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData (macOS 14+), Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), Swift Package Manager.

---

## Build & Test Commands (READ FIRST — used by every task)

This is an all-SPM project. Xcode must be selected so the macOS SDK resolves; **every** `swift build` / `swift test` invocation MUST be prefixed with `DEVELOPER_DIR`:

```bash
# Run from the repo root: /Users/manu/Developer/lume
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Run a single test by its bare function name (Swift Testing tests are **top-level free functions**, not methods, except `RowSelectionTests` which is a `@Suite struct`):

```bash
# A free-function test (LibraryStore/TagStore style):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter myTestFunctionName
# A suite-method test (RowSelectionTests):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RowSelectionTests
```

GUI behavior is verified manually by the user (no headless GUI harness exists) — see the **Manual Verification Checklist** at the end.

**Test idioms in this repo (match them exactly):**
- Pure-logic suites (`RowSelectionTests`) use `@Suite struct Name { @Test func … { #expect(…) } }`.
- Store suites use **top-level** `@MainActor @Test func name() throws { … }` plus a file-private `makeStore()` that returns `(store: LibraryStore, container: ModelContainer)`. **Every store test retains the container for its whole body** with `defer { withExtendedLifetime(container) {} }` — a `ModelContext` whose in-memory container deallocated crashes with SIGTRAP. Do not omit this.
- The store `makeStore()` container is built with: `ModelContainer(for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `Sources/LumeApp/Sidebar/SidebarRow.swift` | Modify | Row-id grammar. Add `SidebarSection.group`, a `GroupRow` id helper (group header + file-under-group ids), and a non-breaking `decode()` that returns a file URL for `groupfile` ids and the browser/pinned ids exactly as today. |
| `Frameworks/LibraryKit/LibraryStore.swift` | Modify | Add `createEmptyTag(named:)`, `removeTag(named:fromPath:)`; remove the automatic `pruneOrphanTags()` calls (keep the method callable explicitly). |
| `Frameworks/DocumentKit/GroupSort.swift` | Create | Pure helper: sort a tag's files by effective display name (override → filename), tie-broken by path; expose `GroupSort.sorted(_:displayNameForPath:)`. |
| `Sources/LumeApp/AppModel.swift` | Modify | Remove all tag-filter state/methods. Add `tag(_:withTagNamed:)` (drag-to-tag), `createGroup(named:)`, group expand state (`expandedGroups`), `copyPaths(forGroupNamed:)`, `removeFromGroup(path:tagNamed:)`, and group-aware selection helpers. Fix `clickRow` so a pinned/real folder single-click only selects (no inline expand). |
| `Frameworks/DocumentKit/GroupSortTests`… | — | (tests live in `Tests/LumeCoreTests/`, see below) |
| `Sources/LumeApp/Sidebar/GroupsSection.swift` | Create | The GROUPS `Section`: a flat `ForEach` of tags as expandable folders, the `＋ New Group` row, group header rows, file-under-group rows, drag-to-tag drop, and both context menus. |
| `Sources/LumeApp/Sidebar/SidebarView.swift` | Modify | Replace `tagsSection` with `GroupsSection`. Remove `activeFilterBar`, the `tagFilteredPaths` threading, and the tag-filter fields from `RowOrderSignature`. Extend `computeOrderedRowIDs` to include expanded group rows. |
| `Sources/LumeApp/Sidebar/FileTreeView.swift` | Modify | Remove the `tagFilteredPaths` parameter + filter branch from `FileTreeView` and `visibleChildren`. (Browser no longer filters by tag.) |
| `Sources/LumeApp/Sidebar/TagManagerSheet.swift` | Modify | Remove the now-deleted `model.removeTagFilter(…)` calls (the Manage Tags sheet stays — it edits tags, which now drive GROUPS). |
| `Tests/LumeCoreTests/GroupRowTests.swift` | Create | Round-trip tests for the extended `SidebarRow`/`GroupRow` id grammar (paths containing `|`, distinct ids per owning group). |
| `Tests/LumeCoreTests/GroupSortTests.swift` | Create | Tests for `GroupSort.sorted`. |
| `Tests/LumeCoreTests/GroupStoreTests.swift` | Create | Tests for `createEmptyTag`, `removeTag(named:fromPath:)`, empty-group-persists (no auto-prune). |
| `Tests/LumeCoreTests/TagStoreTests.swift` | Modify | Delete the two tests that asserted automatic pruning (`setMetaPrunesNewlyOrphanedTags`); keep the explicit `pruneOrphanTagsDeletesUnreferencedTags` test. |
| `Tests/LumeCoreTests/TagFilterStoreTests.swift` | Keep | `paths(taggedWithAll:)` / `paths(taggedWithAny:)` / `mergeTags` stay (the store helpers remain; only the AppModel filter *state* is removed). No change. |

---

## Important verified facts (do not re-derive)

- `SidebarRow.id` is `"\(section.rawValue)|\(isDirectory ? "d" : "f")|\(url.path)"`; `decode()` splits `maxSplits: 2` so paths may contain `|`.
- `enum SidebarSection: String { case pinned, browser }`.
- `SidebarRow.decode(_:)` is consumed by `AppModel`: `selectedRowURL`, `selectedURLs`, `selectedFolderURLs`, `pinSelection`, `trash`, `openIfSingleFileSelected`, and the `.tag(…)` modifiers in views. **A group-header row id must decode to `nil`** (it's not a real file) so these collections silently skip it; **a file-under-group row id must decode to its real file URL** so Copy Paths / open / selection work.
- `AppModel.selectionSection` derives from the id prefix and returns `.pinned` only when every id starts with `"pinned"`, else `.browser`. Group/groupfile ids therefore fall into `.browser` — acceptable for the action bar (Copy Paths + Tag… work; Pin pins the real files).
- `LibraryStore` tag ops verified: `allTags()`, `existingTag(named:)` (private), `tag(named:)` (private, fetch-or-create with cycling color), `recolorTag`, `renameTag` (merges on clash), `deleteTag`, `mergeTags`, `pruneOrphanTags` (`@discardableResult`), `files(taggedWith:)`, `paths(taggedWith:)`, `setMeta`. `setMeta` currently calls `pruneOrphanTags()` at its tail (line ~128) — **that call is removed in Task 5**.
- `tagColor(_ index:)` (in `Frameworks/LumeUI/TagChip.swift`) bridges a palette index → SwiftUI `Color`. `TagSwatchPicker` and `TagChip` are public.
- `AppModel.store` is `model.libraryContext.map { LibraryStore(context: $0) }` — may be `nil`; always guard.
- Display name for a path in views: `model.displayNames[path]` (a `[String:String]`), or `model.displayName(forPath:)`. The effective name is `displayName ?? url.lastPathComponent`.
- `PathExport.clipboardString(for: [URL])` joins `.path` with `"\n"`.

---

# Phase A — Model & Store (pure, testable)

## Task 1: Extend the row-id grammar (`SidebarRow` + `GroupRow`)

**Files:**
- Modify: `Sources/LumeApp/Sidebar/SidebarRow.swift`
- Test: `Tests/LumeCoreTests/GroupRowTests.swift` (create)

The `SidebarRow` type lives in the `LumeApp` executable target, which is **not** unit-testable from `LumeCoreTests`. To keep the grammar testable, we move the pure id-encoding/decoding into a small value type in a testable framework. Put it in `SelectionKit` (already a dependency of nothing app-specific and imported by tests).

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/GroupRowTests.swift`:

```swift
import Testing
@testable import SelectionKit

@Suite struct GroupRowTests {

    // MARK: group header ids

    @Test func groupHeaderIDRoundTrips() {
        let id = GroupRowID.header(tagName: "project-x")
        #expect(id == "group|g|project-x")
        let decoded = GroupRowID.decode(id)
        #expect(decoded == .header(tagName: "project-x"))
    }

    @Test func groupHeaderIDPreservesPipeInTagName() {
        // Tag names can theoretically contain "|"; the header has exactly one
        // payload field, so split with maxSplits:2 keeps the remainder intact.
        let id = GroupRowID.header(tagName: "a|b")
        #expect(GroupRowID.decode(id) == .header(tagName: "a|b"))
    }

    // MARK: file-under-group ids

    @Test func groupFileIDRoundTrips() {
        let id = GroupRowID.file(tagName: "project-x", path: "/Users/me/a.md")
        #expect(id == "groupfile|f|project-x|/Users/me/a.md")
        #expect(GroupRowID.decode(id) == .file(tagName: "project-x", path: "/Users/me/a.md"))
    }

    @Test func groupFileIDPreservesPipeInPath() {
        // The PATH (last field) may contain "|"; only the first 3 separators are
        // structural, so the path remainder is reassembled verbatim.
        let id = GroupRowID.file(tagName: "grp", path: "/x/a|b.md")
        #expect(GroupRowID.decode(id) == .file(tagName: "grp", path: "/x/a|b.md"))
    }

    @Test func sameFileUnderTwoGroupsHasDistinctIDs() {
        let a = GroupRowID.file(tagName: "alpha", path: "/x/a.md")
        let b = GroupRowID.file(tagName: "beta", path: "/x/a.md")
        #expect(a != b)
    }

    // MARK: cross-grammar isolation (browser/pinned ids are NOT group ids)

    @Test func decodeRejectsBrowserAndPinnedIDs() {
        #expect(GroupRowID.decode("browser|f|/x/a.md") == nil)
        #expect(GroupRowID.decode("pinned|d|/x/dir") == nil)
        #expect(GroupRowID.decode("garbage") == nil)
    }

    @Test func fileURLForGroupFileID() {
        // A groupfile id resolves to its real file URL (drives Copy Paths / open).
        let id = GroupRowID.file(tagName: "g", path: "/x/a.md")
        #expect(GroupRowID.fileURL(forID: id)?.path == "/x/a.md")
        // A header id has no file URL.
        #expect(GroupRowID.fileURL(forID: GroupRowID.header(tagName: "g")) == nil)
        // A browser id has no GROUP file URL (handled by SidebarRow.decode instead).
        #expect(GroupRowID.fileURL(forID: "browser|f|/x/a.md") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GroupRowTests`
Expected: FAIL — compile error, `GroupRowID` is not defined in `SelectionKit`.

- [ ] **Step 3: Add the `GroupRowID` value type to `SelectionKit`**

Create `Frameworks/SelectionKit/GroupRowID.swift`:

```swift
import Foundation

/// Row-id grammar for the GROUPS region, kept PURE (no SwiftUI/SwiftData) so it
/// is unit-testable. The unified sidebar packs several row kinds into one
/// `Set<String>` selection; GROUPS adds two:
///
///   • a group HEADER row   →  "group|g|<tagName>"
///   • a FILE under a group →  "groupfile|f|<tagName>|<path>"
///
/// The owning tag name is part of the file id, so the SAME real file under two
/// different groups produces two DISTINCT ids (required: a multi-tag file appears
/// under multiple groups simultaneously). Paths (and, defensively, tag names) may
/// contain "|", so decoding splits off a fixed number of leading separators and
/// keeps the final field verbatim.
public enum GroupRowID: Equatable, Sendable {
    case header(tagName: String)
    case file(tagName: String, path: String)

    /// Encode a group-header id.
    public static func header(tagName: String) -> String {
        "group|g|\(tagName)"
    }

    /// Encode a file-under-group id.
    public static func file(tagName: String, path: String) -> String {
        "groupfile|f|\(tagName)|\(path)"
    }

    /// Decode a GROUPS row id, or nil if it isn't one (browser/pinned/garbage).
    public static func decode(_ id: String) -> GroupRowID? {
        if id.hasPrefix("group|g|") {
            // "group|g|<tagName>" — one payload field, keep the remainder whole.
            let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "group", parts[1] == "g" else { return nil }
            return .header(tagName: String(parts[2]))
        }
        if id.hasPrefix("groupfile|f|") {
            // "groupfile|f|<tagName>|<path>" — two payload fields; the FIRST is the
            // tag name (no "|" in practice but tolerated below by the path winning
            // the remainder), the LAST is the path (may contain "|").
            let parts = id.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "groupfile", parts[1] == "f" else { return nil }
            return .file(tagName: String(parts[2]), path: String(parts[3]))
        }
        return nil
    }

    /// The real file URL for a file-under-group id, or nil for a header id or any
    /// non-GROUPS id. Lets the app reuse one collection (e.g. Copy Paths) across
    /// group-file rows without special-casing.
    public static func fileURL(forID id: String) -> URL? {
        if case let .file(_, path) = decode(id) { return URL(fileURLWithPath: path) }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GroupRowTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Wire `SidebarRow.decode` to recognize group ids and extend the section enum**

In `Sources/LumeApp/Sidebar/SidebarRow.swift`, replace the entire file contents with:

```swift
import Foundation
import SelectionKit

/// Which sidebar section a row belongs to (rows of the same path in different
/// sections must stay distinct for `List(selection:)`). `group` covers GROUPS
/// region rows; their full id grammar lives in `SelectionKit.GroupRowID`.
enum SidebarSection: String { case pinned, browser, group }

/// One selectable real-file/folder row in the unified sidebar (FAVORITES + OPEN
/// FOLDER). GROUPS rows use `GroupRowID` instead.
struct SidebarRow: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var id: String { "\(section.rawValue)|\(isDirectory ? "d" : "f")|\(url.path)" }

    /// Decode a row id back to its file + kind. Handles BOTH the real-file grammar
    /// ("section|d|/path") AND a file-under-group id ("groupfile|f|tag|/path"),
    /// returning the file URL in both cases so selection-derived URL collections
    /// (Copy Paths, open, pin) work uniformly. A GROUP HEADER id ("group|g|tag")
    /// decodes to nil — it isn't a real file. Paths may contain "|".
    static func decode(_ id: String) -> (url: URL, isDirectory: Bool)? {
        // File-under-group rows resolve to their real file.
        if let url = GroupRowID.fileURL(forID: id) {
            return (url, false)
        }
        // Group headers are not files.
        if GroupRowID.decode(id) != nil { return nil }
        // Real pinned/browser rows.
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (URL(fileURLWithPath: String(parts[2])), parts[1] == "d")
    }
}
```

- [ ] **Step 6: Verify the whole package still builds**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS (build succeeds).

- [ ] **Step 7: Commit**

```bash
git add Frameworks/SelectionKit/GroupRowID.swift Sources/LumeApp/Sidebar/SidebarRow.swift Tests/LumeCoreTests/GroupRowTests.swift
git commit -m "feat(groups): extend row-id grammar with group header + file-under-group ids

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Pure group file-sort helper (`GroupSort`)

**Files:**
- Create: `Frameworks/DocumentKit/GroupSort.swift`
- Test: `Tests/LumeCoreTests/GroupSortTests.swift` (create)

A group lists its files sorted alphabetically by *effective display name* (override → filename), tie-broken by full path so same-named files in different folders have a stable order. Keep it pure (no SwiftData) and testable.

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/GroupSortTests.swift`:

```swift
import Testing
@testable import DocumentKit

@Suite struct GroupSortTests {

    @Test func sortsByEffectiveDisplayNameCaseInsensitively() {
        let paths = ["/x/Zebra.md", "/x/apple.md", "/x/Mango.md"]
        let sorted = GroupSort.sorted(paths) { _ in nil }   // no overrides → filename
        #expect(sorted == ["/x/apple.md", "/x/Mango.md", "/x/Zebra.md"])
    }

    @Test func displayNameOverrideWins() {
        // Two .env files; their overrides drive the order, not the filename.
        let paths = ["/a/.env", "/b/.env"]
        let names = ["/a/.env": "Zeta keys", "/b/.env": "Alpha keys"]
        let sorted = GroupSort.sorted(paths) { names[$0] }
        #expect(sorted == ["/b/.env", "/a/.env"])   // Alpha before Zeta
    }

    @Test func tieBreaksByFullPathWhenNamesEqual() {
        // Identical effective names → deterministic order by path.
        let paths = ["/z/readme.md", "/a/readme.md"]
        let sorted = GroupSort.sorted(paths) { _ in nil }
        #expect(sorted == ["/a/readme.md", "/z/readme.md"])
    }

    @Test func emptyInputIsEmpty() {
        #expect(GroupSort.sorted([]) { _ in nil } == [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GroupSortTests`
Expected: FAIL — `GroupSort` not defined.

- [ ] **Step 3: Write the implementation**

Create `Frameworks/DocumentKit/GroupSort.swift`:

```swift
import Foundation

/// Pure ordering for the files inside a GROUP (a tag-folder). Files are sorted by
/// their EFFECTIVE display name — the user override if present, else the filename
/// — case-insensitively, tie-broken by full path so same-named files in different
/// folders keep a stable, deterministic order. Never touches disk or SwiftData;
/// the caller supplies display-name overrides via the closure.
public enum GroupSort {
    public static func sorted(_ paths: [String],
                              displayNameForPath: (String) -> String?) -> [String] {
        func key(_ path: String) -> String {
            let name = displayNameForPath(path) ?? (path as NSString).lastPathComponent
            return name
        }
        return paths.sorted { lhs, rhs in
            let lk = key(lhs), rk = key(rhs)
            let cmp = lk.localizedCaseInsensitiveCompare(rk)
            if cmp == .orderedSame { return lhs < rhs }   // tie-break by path
            return cmp == .orderedAscending
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GroupSortTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Frameworks/DocumentKit/GroupSort.swift Tests/LumeCoreTests/GroupSortTests.swift
git commit -m "feat(groups): pure GroupSort helper (effective-name ordering, path tie-break)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `LibraryStore.createEmptyTag(named:)`

**Files:**
- Modify: `Frameworks/LibraryKit/LibraryStore.swift` (Tags section, after `tag(named:)` ~line 297)
- Test: `Tests/LumeCoreTests/GroupStoreTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/GroupStoreTests.swift`:

```swift
import Testing
import SwiftData
@testable import LibraryKit

// Retain the in-memory container for the whole test body (SIGTRAP otherwise on
// this toolchain). Same pattern as LibraryStoreTests / TagStoreTests.
@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

@MainActor @Test func createEmptyTagCreatesAPersistentEmptyTag() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "project-x")
    #expect(store.allTags().map(\.name) == ["project-x"])
    #expect(store.files(taggedWith: "project-x").isEmpty)
    // It gets a cycling palette color like any new tag (first tag → index 0).
    #expect(store.colorIndex(forTagNamed: "project-x") == 0)
}

@MainActor @Test func createEmptyTagIsIdempotentByName() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "dup")
    store.createEmptyTag(named: "dup")   // no second tag, name is unique
    #expect(store.allTags().filter { $0.name == "dup" }.count == 1)
}

@MainActor @Test func createEmptyTagTrimsAndRejectsBlank() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "   spaced   ")
    store.createEmptyTag(named: "    ")     // blank → ignored
    #expect(store.allTags().map(\.name) == ["spaced"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter createEmptyTag`
Expected: FAIL — `createEmptyTag` not defined.

- [ ] **Step 3: Write the implementation**

In `Frameworks/LibraryKit/LibraryStore.swift`, inside the `// MARK: Tags` section, immediately AFTER the `recolorTag(named:colorIndex:)` method (around line 223), add:

```swift
    /// Create a brand-new, EMPTY tag (a GROUP with no files yet). Trims the name,
    /// ignores blanks, and is idempotent by name (reuses an existing tag). New
    /// tags get the next cycling palette color, like any tag created via `setMeta`.
    /// Empty tags persist — they are NOT auto-pruned (see the GROUPS design: a
    /// user-created group with zero files is valid).
    public func createEmptyTag(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, existingTag(named: name) == nil else { return }
        context.insert(Tag(name: name, colorIndex: nextColorIndex()))
        try? context.save()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter createEmptyTag`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Frameworks/LibraryKit/LibraryStore.swift Tests/LumeCoreTests/GroupStoreTests.swift
git commit -m "feat(groups): LibraryStore.createEmptyTag for + New Group

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `LibraryStore.removeTag(named:fromPath:)`

**Files:**
- Modify: `Frameworks/LibraryKit/LibraryStore.swift` (Tags section)
- Test: `Tests/LumeCoreTests/GroupStoreTests.swift` (append)

Untag exactly one tag from one file (the "Remove from {group}" context action). The file stays on disk and keeps its other tags; the tag stays even if this was its last file (empty groups persist).

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/GroupStoreTests.swift`:

```swift
@MainActor @Test func removeTagFromPathLeavesOtherTagsIntact() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["alpha", "beta"])
    store.removeTag(named: "alpha", fromPath: "/a.md")

    // The file keeps "beta"; only "alpha" was removed from it.
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["beta"])
    // "alpha" no longer carries this file.
    #expect(store.files(taggedWith: "alpha").isEmpty)
}

@MainActor @Test func removeTagDoesNotPruneTheNowEmptyGroup() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["solo"])
    store.removeTag(named: "solo", fromPath: "/a.md")

    // The tag is now empty but MUST persist (empty groups are valid).
    #expect(store.allTags().map(\.name) == ["solo"])
    #expect(store.files(taggedWith: "solo").isEmpty)
}

@MainActor @Test func removeTagIsSafeForUnknownTagOrPath() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["x"])
    store.removeTag(named: "ghost", fromPath: "/a.md")  // unknown tag
    store.removeTag(named: "x", fromPath: "/missing.md") // unknown path
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["x"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter removeTag`
Expected: FAIL — `removeTag(named:fromPath:)` not defined.

- [ ] **Step 3: Write the implementation**

In `Frameworks/LibraryKit/LibraryStore.swift`, in the `// MARK: Tags` section, after `createEmptyTag` (from Task 3), add:

```swift
    /// Remove ONE tag from ONE file (the GROUPS "Remove from {group}" action). The
    /// file stays on disk and keeps every other tag; the tag persists even if this
    /// was its last file (empty groups are valid — no auto-prune).
    public func removeTag(named name: String, fromPath path: String) {
        guard let meta = meta(for: path) else { return }
        meta.tags.removeAll { $0.name == name }
        try? context.save()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter removeTag`
Expected: PASS (3 tests). Note `removeTagFromPathLeavesOtherTagsIntact` / `removeTagDoesNotPruneTheNowEmptyGroup` still pass even before Task 5 because `removeTag` itself never calls prune — but `setMeta` does today, which is irrelevant here since we never re-call `setMeta`.

- [ ] **Step 5: Commit**

```bash
git add Frameworks/LibraryKit/LibraryStore.swift Tests/LumeCoreTests/GroupStoreTests.swift
git commit -m "feat(groups): LibraryStore.removeTag(named:fromPath:) for Remove-from-group

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Remove the orphan-tag auto-prune (empty groups persist)

**Files:**
- Modify: `Frameworks/LibraryKit/LibraryStore.swift` (`setMeta` ~line 128; `mergeTags` ~line 287)
- Modify: `Tests/LumeCoreTests/TagStoreTests.swift` (remove the auto-prune assertions)
- Test: `Tests/LumeCoreTests/GroupStoreTests.swift` (append a persistence test)

Audit of every `pruneOrphanTags()` call site (verified by grep): `setMeta` (line ~128), `mergeTags` (line ~287), and the explicit public `pruneOrphanTags()` method itself. Remove the call in `setMeta` (so clearing a file's tags no longer deletes the now-empty tag — it remains a valid empty group). **Keep** the call in `mergeTags` — merging is an explicit consolidation where the emptied *source* tags genuinely should disappear (a merge is "fold A into B and delete A"), and the existing `mergeTagsPrunesEmptiedTags` test depends on it. Keep the public `pruneOrphanTags()` method available for explicit use.

- [ ] **Step 1: Write the failing test (empty group persists after clearing a file's tags)**

Append to `Tests/LumeCoreTests/GroupStoreTests.swift`:

```swift
@MainActor @Test func clearingLastFilesTagsKeepsTheEmptyGroup() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["solo"])
    #expect(store.allTags().map(\.name) == ["solo"])

    // Clearing the only file's tags MUST NOT delete the "solo" group anymore.
    store.setMeta(path: "/a.md", info: "", tagNames: [])
    #expect(store.allTags().map(\.name) == ["solo"])   // empty group persists
    #expect(store.files(taggedWith: "solo").isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter clearingLastFilesTagsKeepsTheEmptyGroup`
Expected: FAIL — currently `setMeta` prunes the orphan, so `allTags()` is empty, not `["solo"]`.

- [ ] **Step 3: Remove the auto-prune call from `setMeta`**

In `Frameworks/LibraryKit/LibraryStore.swift`, in `setMeta(path:info:tagNames:displayName:)`, delete these three trailing lines (currently ~lines 126–128):

```swift
        // Removing a tag from its last file would otherwise leave a dangling
        // tag in the sidebar; prune so "clear the field" actually removes it.
        pruneOrphanTags()
```

So the method now ends with `try? context.save()`.

- [ ] **Step 4: Run the new test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter clearingLastFilesTagsKeepsTheEmptyGroup`
Expected: PASS.

- [ ] **Step 5: Remove the now-obsolete auto-prune assertion in `TagStoreTests`**

In `Tests/LumeCoreTests/TagStoreTests.swift`, delete the entire `setMetaPrunesNewlyOrphanedTags()` test (currently lines ~108–120):

```swift
@MainActor @Test func setMetaPrunesNewlyOrphanedTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["solo"])
    #expect(store.allTags().map(\.name) == ["solo"])
    store.setMeta(path: "/a.md", info: "", tagNames: [])
    #expect(store.allTags().isEmpty)
    store.setMeta(path: "/x.md", info: "", tagNames: ["shared"])
    store.setMeta(path: "/y.md", info: "", tagNames: ["shared"])
    store.setMeta(path: "/x.md", info: "", tagNames: [])
    #expect(store.allTags().map(\.name) == ["shared"])
    #expect(store.paths(taggedWith: "shared") == ["/y.md"])
}
```

(Leave `pruneOrphanTagsDeletesUnreferencedTags()` — the explicit prune method still works and is still tested.)

- [ ] **Step 6: Run the full suite to confirm green**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS. `mergeTagsPrunesEmptiedTags` still passes (we kept the prune in `mergeTags`); the deleted test no longer runs.

- [ ] **Step 7: Commit**

```bash
git add Frameworks/LibraryKit/LibraryStore.swift Tests/LumeCoreTests/TagStoreTests.swift Tests/LumeCoreTests/GroupStoreTests.swift
git commit -m "feat(groups): stop auto-pruning orphan tags so empty groups persist

Removes pruneOrphanTags() from setMeta (clearing a file's tags no longer
deletes the now-empty group). Kept in mergeTags (explicit consolidation).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Phase B — Removal of tag-filter machinery + pinned-folder click change

## Task 6: Remove tag-filter state & methods from `AppModel`; flip pinned-folder single-click

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift`

This task removes `AppModel` tag-filter members and changes `clickRow` so a single click on a real folder (pinned or browser) **selects only** (no inline expand). It deliberately leaves `SidebarView`/`FileTreeView`/`TagManagerSheet` temporarily referencing removed members — those are fixed in Tasks 7–9. To keep commits compilable, **Tasks 6–9 are committed together** as one "remove tag filter" change. Do all edits, then build once at the end of Task 9.

> NOTE: `RowSelection.revalidate(...)` becomes unused after this task (only `revalidateSelectionForFilter` called it). Leave the pure helper and its tests in `SelectionKit`/`RowSelectionTests` in place — it's harmless dead-but-tested code and removing it churns the selection suite for no benefit. Document this in the code comment below.

- [ ] **Step 1: Delete the tag-filter stored properties**

In `Sources/LumeApp/AppModel.swift`, delete the two properties and their `didSet` blocks (currently lines ~22–29):

```swift
    /// Active tag filter (multi-tag). Empty ⇒ no filtering. Membership is toggled
    /// from the sidebar Tags section and the active-filter bar.
    var activeTagFilters: Set<String> = [] {
        didSet { revalidateSelectionForFilter() }
    }
    /// true = All/AND (intersection), false = Any/OR (union). Defaults to All.
    var tagFilterMatchAll: Bool = true {
        didSet { revalidateSelectionForFilter() }
    }
```

- [ ] **Step 2: Delete the entire `// MARK: - Tag filtering` section**

In `Sources/LumeApp/AppModel.swift`, delete the whole block from the `// MARK: - Tag filtering` comment (line ~288) through the end of `revalidateSelectionForFilter()` (line ~334) — i.e. `hasTagFilter`, `toggleTagFilter`, `removeTagFilter`, `clearTagFilters`, `tagFilteredPaths`, and `revalidateSelectionForFilter`. The block to delete is:

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

    /// After the tag filter changes, drop selection state that now references
    /// hidden FILES so the editor header doesn't keep rendering a file you can no
    /// longer see in the sidebar. Directories stay (still navigable), matching
    /// `FileTreeView.visibleChildren`. When `tagFilteredPaths` is nil (no active
    /// filter) NOTHING is cleared. Called from the filter mutators' didSet.
    private func revalidateSelectionForFilter() {
        guard let allowed = tagFilteredPaths else { return }
        // FILE selection (editor): clear if its path fell out of the allowed set.
        if let file = selectedFile, !allowed.contains(file.path) {
            selectedFile = nil
        }
        // Row selection + keyboard anchor/focus: drop now-hidden file rows.
        let r = RowSelection.revalidate(selection: selectedRowIDs,
                                        anchor: selectionAnchorID,
                                        focus: selectionFocusID,
                                        allowed: allowed)
        if r.selection != selectedRowIDs { selectedRowIDs = r.selection }
        selectionAnchorID = r.anchor
        selectionFocusID = r.focus
    }
```

- [ ] **Step 3: Add a note that `RowSelection.revalidate` is now unused**

Immediately above the `// MARK: - Multi-selection commands` comment (which followed the deleted section), add:

```swift
    // NOTE: the GROUPS redesign removed tag-filtering, so nothing in the app calls
    // `RowSelection.revalidate(...)` anymore. The pure helper (and its tests) are
    // kept in SelectionKit as harmless, still-passing dead code rather than churn
    // the selection suite; reintroduce a caller if filtering ever returns.
```

- [ ] **Step 4: Flip the pinned/real-folder single-click behavior in `clickRow`**

In `Sources/LumeApp/AppModel.swift`, replace the body of `clickRow(id:isDirectory:url:command:shift:)` (the doc-comment may stay, but update the behavior). Replace the final two lines:

```swift
        // Activate only on a plain click (no modifier): reveal the row's content.
        guard !command, !shift else { return }
        if isDirectory { toggleExpanded(url) } else { selectedFile = url }
```

with:

```swift
        // Activate only on a plain click (no modifier). GROUPS redesign: a single
        // click on a real FOLDER (pinned or browser) now ONLY selects — it no
        // longer toggles inline expansion (double-click drills into the browser
        // instead). A single click on a FILE still opens it. Group headers /
        // group files route through their own gestures in GroupsSection, not here.
        guard !command, !shift else { return }
        if !isDirectory { selectedFile = url }
```

Also update the doc comment's final sentence: change "folder → toggle inline expand to reveal its children; file → show its content" to "folder → select only (double-click drills in); file → show its content".

- [ ] **Step 5: (do NOT build yet — continue to Tasks 7–9, then build once)**

No commit yet. `AppModel` now compiles in isolation but `SidebarView`/`FileTreeView`/`TagManagerSheet` still reference removed members. Proceed.

---

## Task 7: Strip `tagFilteredPaths` from `FileTreeView`

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`

- [ ] **Step 1: Remove the `tagFilteredPaths` property and init parameter**

In `Sources/LumeApp/Sidebar/FileTreeView.swift`, delete the property (lines ~9–21):

```swift
    /// The set of paths allowed by the active tag filter, or nil when no filter
    /// is active. Computed ONCE at the top-level (root) `FileTreeView` per region
    /// in `SidebarView` and threaded down into recursive children, so the
    /// O(expanded-folders) SwiftData fetch behind `AppModel.tagFilteredPaths` runs
    /// once per render instead of once per nested `FileTreeView` instance. The
    /// parent computes it inside its view body, so the `@Observable` dependency on
    /// `activeTagFilters`/`tagFilterMatchAll` stays tracked and the tree still
    /// re-renders when filters toggle (or a file's tag membership changes).
    let tagFilteredPaths: Set<String>?
```

- [ ] **Step 2: Simplify the `init`**

Replace the `init` (lines ~25–39) with:

```swift
    init(parent: URL, model: AppModel,
         section: SidebarSection, depth: Int = 0) {
        self.parent = parent
        self.model = model
        self.section = section
        self.depth = depth
        // Seed children at construction so the first render shows them. A bare
        // `ForEach` whose collection is initially empty never fires `.onAppear`,
        // so relying on it to kick off the first load left the tree permanently
        // empty. `.onChange(of: parent)` still handles re-roots on the same view.
        _children = State(initialValue: model.children(of: parent,
                                                        includeHidden: Self.includeHidden(section: section, model: model)))
    }
```

- [ ] **Step 3: Update the recursive child call site**

In `body`, replace the nested `FileTreeView(...)` call (lines ~64–66):

```swift
                FileTreeView(parent: node.url, model: model,
                             section: section, depth: depth + 1,
                             tagFilteredPaths: tagFilteredPaths)
```

with:

```swift
                FileTreeView(parent: node.url, model: model,
                             section: section, depth: depth + 1)
```

- [ ] **Step 4: Remove the tag-filter branch from `visibleChildren`**

In `FileTreeView.visibleChildren`, delete the block (lines ~98–104):

```swift
        if let allowed = tagFilteredPaths {
            // Set-based filter: `allowed` is the intersection (All) or union (Any)
            // of the active tags' paths, computed ONCE at the root FileTreeView and
            // threaded down here. Keep directories (so you can navigate into them) +
            // files in the allowed set. Covers BOTH regions since filtering lives here.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
```

Also update the struct's top doc-comment "honoring files-only + tag filter" → "honoring files-only".

---

## Task 8: Strip tag-filter machinery from `SidebarView`

**Files:**
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift`

- [ ] **Step 1: Drop the `tagFilteredPaths` param from `computeOrderedRowIDs` and its callers**

In `Sources/LumeApp/Sidebar/SidebarView.swift`, change `computeOrderedRowIDs(tagFilteredPaths:)` to take no argument and drop the threading. Replace the method (lines ~52–77) with:

```swift
    private func computeOrderedRowIDs() -> [String] {
        var ids: [String] = []

        // GROUPS region first (matches the rendered order: GROUPS, FAVORITES,
        // OPEN FOLDER). A group header row, then — when expanded — one file row
        // per tagged file in sorted order.
        for tag in tags {
            ids.append(GroupRowID.header(tagName: tag.name))
            guard model.expandedGroups.contains(tag.name) else { continue }
            for path in model.sortedGroupFilePaths(forTagNamed: tag.name) {
                ids.append(GroupRowID.file(tagName: tag.name, path: path))
            }
        }

        func walk(_ url: URL, isDir: Bool, section: SidebarSection, includeHidden: Bool) {
            ids.append(SidebarRow(url: url, isDirectory: isDir, section: section).id)
            guard isDir, model.expandedPaths.contains(url.path) else { return }
            for child in visibleChildren(of: url, section: section, includeHidden: includeHidden) {
                walk(child.url, isDir: child.isDirectory, section: section, includeHidden: includeHidden)
            }
        }

        for fav in visibleFavorites {
            walk(URL(fileURLWithPath: fav.path), isDir: fav.kindRaw == "folder",
                 section: .pinned, includeHidden: false)
        }
        if let root = model.browseRoot {
            for child in visibleChildren(of: root, section: .browser,
                                         includeHidden: model.showBrowserHidden) {
                walk(child.url, isDir: child.isDirectory, section: .browser,
                     includeHidden: model.showBrowserHidden)
            }
        }
        return ids
    }
```

> `model.sortedGroupFilePaths(forTagNamed:)` and `model.expandedGroups` are added in Task 10. This view file will not compile until Task 10 is done — that's fine; the build gate is at the end of Task 10.

- [ ] **Step 2: Remove the `tagFilteredPaths` parameter from `visibleChildren`**

Replace the `visibleChildren` method (lines ~116–135) with:

```swift
    /// The same filtering `FileTreeView.visibleChildren` applies, hoisted here so
    /// the keyboard order matches the rendered order exactly.
    /// ⚠️ CROSS-PHASE DRIFT: duplicates `FileTreeView.visibleChildren`
    /// (FileTreeView.swift). Keep them in lockstep on any future change.
    private func visibleChildren(of parent: URL, section: SidebarSection,
                                 includeHidden: Bool) -> [FileNode] {
        var nodes = model.children(of: parent, includeHidden: includeHidden)
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if section == .pinned, !model.showPinnedHidden {
            nodes = nodes.filter { !model.hiddenPaths.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }
```

- [ ] **Step 3: Simplify `rowOrderSignature`**

Replace `rowOrderSignature` (lines ~94–108) and the `RowOrderSignature` struct (lines ~572–584) so the tag-filter fields are gone and the group-expand set is added. Replace the computed property with:

```swift
    private var rowOrderSignature: RowOrderSignature {
        RowOrderSignature(
            expanded: model.expandedPaths,
            expandedGroups: model.expandedGroups,
            tagNames: tags.map(\.name),
            browseRoot: model.browseRoot?.path,
            favoritePaths: visibleFavorites.map(\.path),
            filesOnly: model.filesOnly,
            browseFilter: model.browseFilter,
            showBrowserHidden: model.showBrowserHidden,
            showPinnedHidden: model.showPinnedHidden,
            hiddenPaths: model.hiddenPaths,
            displayNames: model.displayNames
        )
    }
```

And replace the struct definition with:

```swift
private struct RowOrderSignature: Equatable {
    let expanded: Set<String>
    let expandedGroups: Set<String>
    let tagNames: [String]
    let browseRoot: String?
    let favoritePaths: [String]
    let filesOnly: Bool
    let browseFilter: String
    let showBrowserHidden: Bool
    let showPinnedHidden: Bool
    let hiddenPaths: Set<String>
    // Folded in so a group's file order re-walks when a display name changes
    // (group rows sort by effective display name).
    let displayNames: [String: String]
}
```

- [ ] **Step 4: Rewrite `body` — swap sections, drop the filter bar**

Replace the `body` from the `let tagFilteredPaths = model.tagFilteredPaths` line through the `.safeAreaInset(edge: .top)` block. Specifically:

Replace lines ~137–164:

```swift
    var body: some View {
        // Compute the active tag-filter path set ONCE per render. ...
        let tagFilteredPaths = model.tagFilteredPaths
        return List(selection: selection) {
            pinnedSection(tagFilteredPaths: tagFilteredPaths)
            if !tags.isEmpty { tagsSection }
            browserSection(tagFilteredPaths: tagFilteredPaths)
        }
        .listStyle(.sidebar)
        .background(MetaIndexLoader(model: model))
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                topBar
                if model.hasTagFilter {
                    activeFilterBar(matchCount: tagFilteredPaths?.count ?? 0)
                }
            }
        }
```

with:

```swift
    var body: some View {
        List(selection: selection) {
            GroupsSection(model: model, tags: tags)
            pinnedSection()
            browserSection()
        }
        .listStyle(.sidebar)
        .background(MetaIndexLoader(model: model))
        .safeAreaInset(edge: .top) {
            topBar
        }
```

- [ ] **Step 5: Update the two `computeOrderedRowIDs(...)` call sites (onChange + onAppear)**

Replace (lines ~185–190):

```swift
        .onChange(of: rowOrderSignature) { _, _ in
            model.orderedVisibleRowIDs = computeOrderedRowIDs(tagFilteredPaths: model.tagFilteredPaths)
        }
        .onAppear {
            model.orderedVisibleRowIDs = computeOrderedRowIDs(tagFilteredPaths: model.tagFilteredPaths)
        }
```

with:

```swift
        .onChange(of: rowOrderSignature) { _, _ in
            model.orderedVisibleRowIDs = computeOrderedRowIDs()
        }
        .onAppear {
            model.orderedVisibleRowIDs = computeOrderedRowIDs()
        }
```

- [ ] **Step 6: Delete `activeFilterBar(matchCount:)`**

Delete the entire `activeFilterBar(matchCount:)` method (lines ~297–333), including its doc comment.

- [ ] **Step 7: Delete the `tagsSection` view**

Delete the entire `@ViewBuilder private var tagsSection: some View { … }` block (lines ~421–486), including the `.sheet(item: $renamingTag)` and `.sheet(isPresented: $showingTagManager)` modifiers attached to it.

- [ ] **Step 8: Re-home the tag-rename and Manage-Tags sheets onto the List**

The two sheets and their `@State` (`renamingTag`, `showingTagManager`) are still wanted (the Manage Tags panel survives; GroupsSection will trigger renames). Keep the `@State private var renamingTag: TagRef?` and `@State private var showingTagManager = false` declarations at the top of `SidebarView`. Attach the sheets to the `List` instead. In `body`, immediately after `.background(MetaIndexLoader(model: model))`, add:

```swift
        .sheet(item: $renamingTag) { ref in
            TagRenameSheet(model: model, oldName: ref.name) {
                renamingTag = nil
            }
        }
        .sheet(isPresented: $showingTagManager) {
            TagManagerSheet(model: model, isPresented: $showingTagManager)
        }
```

> `GroupsSection` (Task 11) is given bindings to `renamingTag` and `showingTagManager` so its context menus and header button drive these sheets.

- [ ] **Step 9: Update `pinnedSection` and `browserSection` signatures (drop the param)**

Replace `@ViewBuilder private func pinnedSection(tagFilteredPaths: Set<String>?) -> some View {` with `@ViewBuilder private func pinnedSection() -> some View {`, and inside it replace the nested `FileTreeView(...)` call (lines ~394–396):

```swift
                        FileTreeView(parent: url, model: model,
                                     section: .pinned, depth: 1,
                                     tagFilteredPaths: tagFilteredPaths)
```

with:

```swift
                        FileTreeView(parent: url, model: model,
                                     section: .pinned, depth: 1)
```

Replace `@ViewBuilder private func browserSection(tagFilteredPaths: Set<String>?) -> some View {` with `@ViewBuilder private func browserSection() -> some View {`, and inside it replace the `FileTreeView(...)` call (lines ~494–496):

```swift
                FileTreeView(parent: root, model: model,
                             section: .browser, depth: 0,
                             tagFilteredPaths: tagFilteredPaths)
```

with:

```swift
                FileTreeView(parent: root, model: model,
                             section: .browser, depth: 0)
```

---

## Task 9: Remove `model.removeTagFilter(...)` calls from `TagManagerSheet`

**Files:**
- Modify: `Sources/LumeApp/Sidebar/TagManagerSheet.swift`

`removeTagFilter` no longer exists. The Manage Tags sheet's only use of it was to drop renamed/merged/deleted names out of the (now-gone) active filter. Delete those four lines.

- [ ] **Step 1: Remove the call in the rename sheet close (line ~64)**

Delete the line `                model.removeTagFilter(ref.name)` inside the `.sheet(item: $renaming)` closure.

- [ ] **Step 2: Remove the call in the inline-rename callback (line ~121)**

Delete the line `                model.removeTagFilter(old)` inside `InlineTagName(...) { old in … }`.

- [ ] **Step 3: Remove the call in the Delete button loop (line ~171)**

Delete the line `                    model.removeTagFilter(n)` inside the `Button("Delete", role: .destructive)` loop, leaving just `store?.deleteTag(named: n)`.

- [ ] **Step 4: Remove the call in the merge composer (line ~208)**

Replace the merge cleanup line:

```swift
                    // Re-point any active filters off merged names onto survivor.
                    for n in names where n != survivor { model.removeTagFilter(n) }
```

with nothing (delete both lines).

- [ ] **Step 5: Build the whole package**

> This is the build gate for Tasks 6–9. `GroupsSection`, `model.expandedGroups`, and `model.sortedGroupFilePaths` are referenced by `SidebarView` (Task 8) but defined in Tasks 10–11. To make the gate pass HERE, temporarily comment out the `GroupsSection(model: model, tags: tags)` line in `SidebarView.body` and the GROUPS block in `computeOrderedRowIDs` and the `expandedGroups` / `displayNames` fields you added to `RowOrderSignature` — **OR** do Tasks 10 and 11 before building. **Recommended:** proceed directly to Task 10 and 11, then build at the end of Task 11. If you build now with the temporary comments, expect PASS; otherwise skip this step's build and continue.

- [ ] **Step 6: (commit deferred to end of Task 11)**

No commit yet — Phase B's removal is committed together with the Phase C AppModel additions and GroupsSection, so the tree is green at the commit.

---

# Phase C — GROUPS UI + AppModel group methods

## Task 10: AppModel group methods (expand state, sort, drag-to-tag, copy-paths, new group, remove-from-group)

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift`

These are mostly thin store/clipboard wiring; the pure logic they delegate to (`GroupSort`, `createEmptyTag`, `removeTag`, `paths`) is already tested. Add a new `// MARK: - Groups` section just before `// MARK: Derived` (the `selectedKind`/`store` block at the end of the file).

- [ ] **Step 1: Add the group state + methods**

In `Sources/LumeApp/AppModel.swift`, add `import` is already present (`LumeCore` re-exports `DocumentKit`/`SelectionKit`; confirm `GroupSort` and `GroupRowID` resolve — they do via `import LumeCore` which already exists at the top of AppModel.swift). Add a stored property near `expandedPaths` (after line ~80 `var expandedPaths: Set<String> = []`):

```swift
    /// Tag NAMES whose GROUP is currently expanded in the GROUPS region. Distinct
    /// from `expandedPaths` (real folders) — a group has no disk folder.
    var expandedGroups: Set<String> = []
```

Then add, just before `// MARK: Derived`:

```swift
    // MARK: - Groups (tag-driven navigator)

    /// Toggle a group's expansion in the GROUPS region (double-click a group).
    func toggleGroupExpanded(_ tagName: String) {
        if expandedGroups.contains(tagName) { expandedGroups.remove(tagName) }
        else { expandedGroups.insert(tagName) }
    }

    /// The file paths in a group, sorted by effective display name (override →
    /// filename), path tie-broken. Drives both the rendered rows and the flat
    /// keyboard order, so they always agree.
    func sortedGroupFilePaths(forTagNamed name: String) -> [String] {
        guard let store else { return [] }
        let paths = store.files(taggedWith: name).map(\.path)
        return GroupSort.sorted(paths) { self.displayNames[$0] }
    }

    /// Create a new, empty, persistent group (the ＋ New Group affordance) and
    /// expand it so it's the obvious current drag/tag target.
    func createGroup(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let store else { return }
        store.createEmptyTag(named: name)
        expandedGroups.insert(name)
    }

    /// Drag-to-tag: add `tagName` to every dropped file's metadata, preserving its
    /// existing info/displayName/other tags. Folders dropped onto a group are
    /// ignored (groups hold files). Creates the tag if it didn't exist.
    func tag(_ urls: [URL], withTagNamed tagName: String) {
        guard let store else { return }
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDir else { continue }
            let existing = store.meta(for: url.path)
            var names = existing?.tags.map(\.name) ?? []
            guard !names.contains(tagName) else { continue }
            names.append(tagName)
            store.setMeta(path: url.path,
                          info: existing?.info ?? "",
                          tagNames: names,
                          displayName: existing?.displayName ?? "")
        }
    }

    /// Remove ONE tag from ONE file (GROUPS "Remove from {group}"). The file stays
    /// on disk and in its other groups; the (possibly now-empty) group persists.
    func removeFromGroup(path: String, tagNamed tagName: String) {
        store?.removeTag(named: tagName, fromPath: path)
    }

    /// Copy every file path in a group to the clipboard, newline-joined absolute
    /// POSIX paths (the AI hand-off), AND as file URLs (Finder/editor paste).
    /// Order matches the group's rendered order.
    func copyPaths(forGroupNamed tagName: String) {
        let urls = sortedGroupFilePaths(forTagNamed: tagName).map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        pb.setString(PathExport.clipboardString(for: urls), forType: .string)
    }
```

- [ ] **Step 2: (build gate moves to Task 11) — proceed to Task 11**

No commit yet. `SidebarView` still references `GroupsSection`, which is created next.

---

## Task 11: `GroupsSection` view (header rows, file rows, expand, ＋ New Group, drag-to-tag, context menus)

**Files:**
- Create: `Sources/LumeApp/Sidebar/GroupsSection.swift`
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (pass sheet bindings into `GroupsSection` — finalize the call)

This is pure SwiftUI wiring; verified manually (GUI). It mirrors the existing row patterns: `.tag(id)` for List selection, `.onTapGesture(count: 2)` for double-click, `.onTapGesture` for single-click via `model.clickRow`, `.contextMenu`, `.dropDestination(for: URL.self)`. Colors via `tagColor(_:)` from `LumeUI`.

- [ ] **Step 1: Create the GroupsSection file**

Create `Sources/LumeApp/Sidebar/GroupsSection.swift`:

```swift
import AppKit
import SwiftUI
import SwiftData
import LumeCore
import LumeUI

/// The GROUPS sidebar region: a flat list of tags as expandable, color-tinted
/// virtual folders. Each group expands to show EVERY file carrying that tag
/// (from anywhere on disk), sorted by effective display name. A ＋ New Group row
/// creates an empty, persistent group. Drag a file onto a group to tag it.
struct GroupsSection: View {
    let model: AppModel
    let tags: [Tag]
    @Binding var renamingTag: TagRef?
    @Binding var showingTagManager: Bool

    @State private var newGroupPromptShown = false
    @State private var newGroupName = ""

    var body: some View {
        Section {
            ForEach(tags) { tag in
                groupHeaderRow(tag)
                if model.expandedGroups.contains(tag.name) {
                    ForEach(model.sortedGroupFilePaths(forTagNamed: tag.name), id: \.self) { path in
                        groupFileRow(tagName: tag.name, path: path)
                    }
                }
            }
            newGroupRow
        } header: {
            HStack {
                Text("GROUPS")
                Spacer()
                Button { showingTagManager = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Manage tags (rename, recolor, merge, delete)")
                .accessibilityLabel("Manage tags")
            }
        }
        .alert("New Group", isPresented: $newGroupPromptShown) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                model.createGroup(named: newGroupName)
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Create an empty group. Tag files (or drag them here) to add them.")
        }
    }

    // MARK: Group header row

    @ViewBuilder private func groupHeaderRow(_ tag: Tag) -> some View {
        let id = GroupRowID.header(tagName: tag.name)
        let isExpanded = model.expandedGroups.contains(tag.name)
        let count = model.sortedGroupFilePaths(forTagNamed: tag.name).count
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 12)
                .onTapGesture { model.toggleGroupExpanded(tag.name) }
                .accessibilityHidden(true)
            Image(systemName: "tag.fill")
                .foregroundStyle(tagColor(tag.colorIndex))
            Text(tag.name).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .tag(id)
        .accessibilityLabel("\(tag.name), group, \(count) file\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(model.selectedRowIDs.contains(id) ? .isSelected : [])
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
            model.toggleGroupExpanded(tag.name)
        }
        // Double-click a group → expand/collapse (no disk folder to drill into).
        .onTapGesture(count: 2) { model.toggleGroupExpanded(tag.name) }
        // Single-click → select only (honoring ⌘/⇧). A group header isn't a file,
        // so clickRow won't open anything; isDirectory:false keeps it from being
        // treated as a real folder.
        .onTapGesture {
            model.clickRow(id: id, isDirectory: false,
                           url: URL(fileURLWithPath: "/"),
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
        // Drag a file onto this group → tag it with this group's name.
        .dropDestination(for: URL.self) { urls, _ in
            model.tag(urls, withTagNamed: tag.name)
            return true
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                renamingTag = TagRef(name: tag.name)
            }
            Menu("Recolor") {
                ForEach(0..<TagPalette.count, id: \.self) { i in
                    Button(TagPalette.swatch(at: i).name) {
                        model.store?.recolorTag(named: tag.name, colorIndex: i)
                    }
                }
            }
            Button("Copy Paths", systemImage: "doc.on.clipboard") {
                model.copyPaths(forGroupNamed: tag.name)
            }
            Divider()
            Button("Delete Group", systemImage: "trash", role: .destructive) {
                model.expandedGroups.remove(tag.name)
                model.store?.deleteTag(named: tag.name)
            }
        }
    }

    // MARK: File-under-group row

    @ViewBuilder private func groupFileRow(tagName: String, path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let id = GroupRowID.file(tagName: tagName, path: path)
        let name = model.displayNames[path] ?? url.lastPathComponent
        HStack(spacing: 6) {
            Spacer().frame(width: 12)   // align under the disclosure column
            Image(systemName: icon(forPath: path))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .tag(id)
        .accessibilityLabel("\(name), in group \(tagName)")
        .accessibilityAddTraits(model.selectedRowIDs.contains(id) ? .isSelected : [])
        // Double-click → open the file in the document pane.
        .onTapGesture(count: 2) {
            model.selectedRowIDs = [id]
            model.selectedFile = url
        }
        // Single-click → select + open (honoring ⌘/⇧). clickRow decodes the
        // groupfile id to this real file URL via SidebarRow.decode, and because
        // isDirectory:false it sets selectedFile through the normal path.
        .onTapGesture {
            model.clickRow(id: id, isDirectory: false, url: url,
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            Button("Open", systemImage: "doc.text") {
                model.selectedRowIDs = [id]
                model.selectedFile = url
            }
            Button("Copy Path", systemImage: "doc.on.clipboard") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([url as NSURL])
                pb.setString(PathExport.clipboardString(for: [url]), forType: .string)
            }
            Button("Remove from “\(tagName)”", systemImage: "tag.slash") {
                model.removeFromGroup(path: path, tagNamed: tagName)
            }
            Divider()
            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: + New Group

    private var newGroupRow: some View {
        Button {
            newGroupName = ""
            newGroupPromptShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .frame(width: 12)
                Text("New Group")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Create an empty group")
        .accessibilityLabel("New Group")
    }

    // MARK: Icon (mirrors FileRow's kind tinting, monochrome here)

    private func icon(forPath path: String) -> String {
        switch FileKind.detect(filename: (path as NSString).lastPathComponent) {
        case .markdown: return "doc.text"
        case .env: return "key.fill"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .previewable: return "doc"
        case .html: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}
```

- [ ] **Step 2: Finalize the `GroupsSection` call in `SidebarView` with the sheet bindings**

In `Sources/LumeApp/Sidebar/SidebarView.swift`, change the `body`'s GROUPS line from `GroupsSection(model: model, tags: tags)` to:

```swift
            GroupsSection(model: model, tags: tags,
                          renamingTag: $renamingTag,
                          showingTagManager: $showingTagManager)
```

- [ ] **Step 3: Build the whole package (the Phase B + C gate)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS. If `FileKind` is unresolved in `GroupsSection.swift`, confirm `import LumeCore` is present (it re-exports `FileSystemKit` where `FileKind` lives) — it is in the file above.

- [ ] **Step 4: Run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (all existing + new tests; the deleted auto-prune test no longer runs).

- [ ] **Step 5: Commit Phase B + C together (green tree)**

```bash
git add Sources/LumeApp/AppModel.swift Sources/LumeApp/Sidebar/SidebarView.swift Sources/LumeApp/Sidebar/FileTreeView.swift Sources/LumeApp/Sidebar/TagManagerSheet.swift Sources/LumeApp/Sidebar/GroupsSection.swift
git commit -m "feat(groups): GROUPS region replaces tag-filter; pinned single-click selects only

- Remove activeTagFilters/tagFilteredPaths/match-all/filter-bar/revalidateSelectionForFilter
- Drop tagFilteredPaths threading from SidebarView + FileTreeView (browser no longer tag-filters)
- Add GroupsSection: expandable color-tinted tag folders, files sorted by display name,
  + New Group, drag-to-tag, group + file context menus, group-scoped Copy Paths
- AppModel: expandedGroups, sortedGroupFilePaths, createGroup, tag(_:withTagNamed:),
  removeFromGroup, copyPaths(forGroupNamed:)
- clickRow: a single click on a real folder now only selects (double-click drills in)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Phase D — Integration polish & verification

## Task 12: Full test run + remove dead `RowOrderSignature` drift & confirm `selectionSection`

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift` (verify only) and `Sources/LumeApp/Sidebar/SidebarView.swift` (verify only)

- [ ] **Step 1: Grep for any lingering removed symbols**

Run:

```bash
grep -rn "activeTagFilters\|tagFilteredPaths\|tagFilterMatchAll\|toggleTagFilter\|removeTagFilter\|clearTagFilters\|hasTagFilter\|revalidateSelectionForFilter\|tagsSection\|activeFilterBar" Sources/ | grep -v ".build"
```

Expected output: empty (no matches). If any remain, remove them.

- [ ] **Step 2: Confirm `selectionSection` tolerates group ids (no code change expected)**

Read `AppModel.selectionSection`. It returns `.pinned` only when every id prefix is `"pinned"`. Group ids (`group`/`groupfile`) yield non-`pinned` prefixes → `.browser`. The bottom action bar (shown for 2+ selections) therefore offers Copy Paths + Tag… + Pin for a multi-group-file selection. Verify by reading the code that no crash path exists (group-header ids decode to `nil` via `SidebarRow.decode`, so `selectedURLs` skips them). No change required — just confirm.

- [ ] **Step 3: Run the full build + test once more**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: build PASS, all tests PASS.

- [ ] **Step 4: Commit (only if Step 1 found and you removed leftovers; otherwise skip)**

```bash
git add -A
git commit -m "chore(groups): remove lingering tag-filter references

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual Verification Checklist

Launch the app and confirm every interaction below. (GUI is verified manually — there is no headless GUI harness.)

Run the app:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run LumeApp
```

**GROUPS region presence & rendering**
- [ ] The sidebar shows three stacked regions top-to-bottom: **GROUPS**, **FAVORITES**, **OPEN FOLDER**.
- [ ] GROUPS lists every existing tag as a row: chevron, color-tinted `tag.fill` icon, tag name, file count.
- [ ] A **＋ New Group** row appears at the bottom of GROUPS.
- [ ] The old **TAGS** section, the **clickable tag filter chips**, and the **active-filter bar** (All/Any picker, match count, Clear) are **gone**.

**Expand / collapse**
- [ ] Double-clicking a group expands it; the chevron flips to down and its files appear.
- [ ] Each file row shows the effective display name (override if set, else filename) plus the muted parent directory path beneath it.
- [ ] Files are ordered alphabetically by effective display name (rename a file via its override and confirm it re-sorts).
- [ ] Double-clicking the group again collapses it.
- [ ] Clicking the chevron alone also toggles expansion.

**Selection**
- [ ] Single-click a group header → it selects (highlighted), nothing opens.
- [ ] Single-click a file under a group → it selects AND opens in the document pane.
- [ ] ⌘-click toggles individual rows into/out of the selection (mix group files + browser files).
- [ ] ⇧-click selects a contiguous range.
- [ ] When 2+ rows are selected, the bottom action bar appears with Copy Paths + Tag….

**Multi-tag file appears under multiple groups**
- [ ] Tag one file with two tags (via the document tag header or Edit Tags…). It appears under BOTH groups.
- [ ] Selecting it under group A and selecting it under group B are distinct selections (the same file under two groups has two row ids — ⌘-clicking both keeps both highlighted).

**Drag-to-tag**
- [ ] Drag a file from OPEN FOLDER onto a group header → the file is added to that group (expand the group to confirm it's listed).
- [ ] Dragging a folder onto a group does nothing (groups hold files only).
- [ ] Dragging a file onto FAVORITES still pins it (unchanged).

**＋ New Group**
- [ ] Click ＋ New Group → a name prompt appears. Enter a name, Create → an empty group with that name appears and is expanded.
- [ ] The empty group **persists** (collapse/expand, switch folders, relaunch — it stays).
- [ ] Drag a file onto the new empty group → the file is added.

**Copy Paths**
- [ ] Right-click a group → Copy Paths → paste into a text editor: newline-joined absolute paths of all the group's files (in sorted order).
- [ ] Select several file rows (any region) → bottom bar Copy Paths → newline-joined paths of exactly those files.
- [ ] Right-click a single file under a group → Copy Path → that one path is on the clipboard.

**Context menus**
- [ ] Group row menu: Rename…, Recolor (submenu of 8 colors), Copy Paths, Delete Group.
- [ ] Rename a group → its name updates in GROUPS; renaming onto an existing group name merges (Manage Tags semantics).
- [ ] Recolor a group → the tinted icon changes color immediately.
- [ ] Delete Group → the group disappears from GROUPS and every file loses that tag (files stay on disk and in other groups).
- [ ] File-under-group menu: Open, Copy Path, **Remove from "{group}"**, Reveal in Finder.
- [ ] Remove from "{group}" → the file leaves THAT group only; it remains in its other groups and on disk. If it was the group's last file, the (now-empty) group still persists.
- [ ] Reveal in Finder → Finder opens with the file selected.

**Pinned-folder click change (Wave-4 regression flip)**
- [ ] Single-click a pinned FOLDER in FAVORITES → it selects only; it does **NOT** auto-expand inline.
- [ ] Double-click a pinned folder → it drills into OPEN FOLDER below (unchanged).
- [ ] Single-click a pinned FILE → it still opens in the document pane.
- [ ] In OPEN FOLDER, single-click a folder → selects only; double-click → drills in.

**Browser no longer tag-filters**
- [ ] With groups present, the OPEN FOLDER browser shows all files regardless of tags (no filtering). The browse text filter (the search field) still works.

**Document tag header still works (and feeds GROUPS)**
- [ ] Open a file, add a tag in the document tag header → the matching group's count increments and the file shows under it.

---

## Self-Review (run before handing off)

**1. Spec coverage** — every spec section maps to a task:
- GROUPS region, flat tag list, expandable color-tinted folders → Task 11 (header rows) + Task 8 (section wiring).
- Each group shows EVERY file with that tag from anywhere, sorted by effective display name with muted path → Task 2 (`GroupSort`) + Task 10 (`sortedGroupFilePaths`) + Task 11 (file rows).
- Multi-tag file under multiple groups; row-id encodes owning-group + path → Task 1 (`GroupRowID.file`) + tests.
- ＋ New Group (prompt, empty persistent Tag, current target) → Task 3 (`createEmptyTag`) + Task 10 (`createGroup`) + Task 11 (prompt/row).
- Single-click select; ⌘/⇧ multi-select; double-click real folder drills; double-click group expand; pinned folders no longer auto-expand → Task 6 (`clickRow`) + Task 11 (gestures).
- Drag file onto group tags it (`model.tag(_:withTagNamed:)`); drag onto FAVORITES pins (unchanged) → Task 10 + Task 11 (drop) + existing `pinDropped`.
- Copy Paths for a group → Task 10 (`copyPaths(forGroupNamed:)`) + Task 11 (menu).
- Context menus (group + file) → Task 11.
- Remove TAGS filter section + filter bar + all listed AppModel filter state + tagFilteredPaths threading; browser no longer filters → Tasks 6, 7, 8, 9.
- Remove orphan auto-prune (audited call sites: setMeta removed, mergeTags kept with rationale, explicit prune retained) → Task 5.
- Keep document tag header/inline editor → untouched (verified: `DocumentTagHeader`, `RowMetaView` not modified).
- Data model reuse, no migration → no `@Model` change anywhere.
- Tests: RowSelection grammar (Task 1 via `GroupRowID`), store group lists/empty persists/remove-single/group-paths (Tasks 3–5, `copyPaths` is GUI/clipboard so manual), pure sort helper (Task 2). ✅

**2. Placeholder scan** — searched the plan for "TBD", "TODO", "similar to Task", "add error handling", "etc." in code steps: none. Every code step contains complete Swift. ✅

**3. Type consistency** — cross-checked names used across tasks:
- `GroupRowID.header(tagName:)`, `GroupRowID.file(tagName:path:)`, `GroupRowID.decode(_:)`, `GroupRowID.fileURL(forID:)` — defined Task 1, used Tasks 8, 11.
- `GroupSort.sorted(_:displayNameForPath:)` — defined Task 2, used Task 10.
- `LibraryStore.createEmptyTag(named:)` — Task 3, used Task 10.
- `LibraryStore.removeTag(named:fromPath:)` — Task 4, used Task 10.
- `AppModel.expandedGroups`, `toggleGroupExpanded`, `sortedGroupFilePaths(forTagNamed:)`, `createGroup(named:)`, `tag(_:withTagNamed:)`, `removeFromGroup(path:tagNamed:)`, `copyPaths(forGroupNamed:)` — defined Task 10, used Tasks 8, 11.
- `GroupsSection(model:tags:renamingTag:showingTagManager:)` — defined Task 11, called Task 8/11.
- `SidebarSection.group` — added Task 1, available everywhere.
- `RowOrderSignature` fields match between `rowOrderSignature` and the struct (Task 8). ✅

No inconsistencies found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-05-groups-tags-navigator.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
**2. Inline Execution** — execute tasks in this session with batch checkpoints.

Note for the executor: Tasks 6–11 form one "remove filter + add GROUPS" unit that only compiles when complete; the single build/test gate is at the end of Task 11, and Phases B+C are committed together there (each earlier phase A task commits independently and stays green).
