# Phase A — Editor Tag Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a collapsible tag header strip at the top of the document pane — shared across every file type — so a file's tags are visible and editable (add / remove / recolor) right where the file is read, persisted through the existing `LibraryStore`.

**Architecture:** A new `DocumentTagHeader` SwiftUI view renders for `model.selectedFile`, reading the file's tags from its `FileMeta` and live colors from a reactive `@Query private var allTags: [Tag]` (the same pattern `RowMetaView`/`MultiTagSheet` already use). A new `TagAddPopover` provides prefix-filtered autocomplete over existing tags plus a "Create" row. `DocumentSurfaceView` wraps the routed viewer in a `VStack(spacing: 0)`, conditionally showing the header above the viewer while preserving the `.id(url)` rebuild. Visibility is a single global flag, `AppModel.showEditorTags`, persisted to `UserDefaults` (`lume.showEditorTags`, default `true`), toggled both by a 🏷 toolbar button in `ContentView` and a ⌃ collapse control inside the header. All writes go through `LibraryStore.setMeta(path:info:tagNames:displayName:)`, reading existing meta first so `info`/`displayName` are preserved; recolor uses `LibraryStore.recolorTag`; orphan pruning already runs inside `setMeta`.

**Tech Stack:** Swift 6, SwiftUI (macOS), SwiftData (`@Query`, `ModelContext`), Swift Testing (`Testing` module). Build: `swift build`; app bundle: `tools/build-app.sh`; tests: `swift test` (the build script sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; export it for `swift build`/`swift test` if the toolchain isn't found).

---

## Verification model

This phase is almost entirely SwiftUI views. The project has **no UI test target**, so views are verified by:
1. **`swift build`** — the change must compile cleanly.
2. **A documented manual checklist** — run the app bundle against a real folder and confirm behavior.

The only **pure logic** introduced is a small, view-independent helper (`TagAddPopover.filteredSuggestions`) that does prefix filtering + dedupe over tag names. That helper is extracted as a free function in `LumeCore` (`TagSuggest.suggestions(...)`) so it can be unit-tested in `Tests/LumeCoreTests/` with the established in-memory `ModelContainer` pattern is NOT even required (it's pure string math), but we still place it in `LumeCore` so the test target (which `@testable import LumeCore`) can reach it.

**Manual run command** (used by every manual-verification step):

```bash
cd /Users/manu/Developer/lume
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./tools/build-app.sh
LUME_OPEN_FOLDER="$HOME/Developer/lume/Sources" \
LUME_OPEN_FILE="$HOME/Developer/lume/Sources/LumeApp/ContentView.swift" \
open -n /Applications/Lume.app   # or: open -n dist/Lume.app
```

> Note: `tools/build-app.sh` runs `swift build -c release`, copies the binary into an app bundle at `dist/Lume.app`, and installs a copy to `/Applications/Lume.app` (falling back to `~/Applications/Lume.app` if `/Applications` isn't writable). The script already exports `DEVELOPER_DIR` internally, but passing it explicitly is harmless and guarantees the toolchain is found. `LUME_OPEN_FOLDER` / `LUME_OPEN_FILE` are honored by `AppModel.applyLaunchEnvironment()`.

---

## Verified codebase facts (read before coding)

These were confirmed by reading the source. **Do not deviate** — later tasks depend on these exact signatures.

- **`AppModel`** (`Sources/LumeApp/AppModel.swift`)
  - `@MainActor @Observable final class AppModel`.
  - `var selectedFile: URL?` (line 11); `var selectedKind: FileKind?` (derived, line 339).
  - Existing persisted-flag pattern (lines 34–37, init lines 63–64):
    ```swift
    var showPinnedHidden = false { didSet { UserDefaults.standard.set(showPinnedHidden, forKey: "lume.showPinnedHidden") } }
    var showBrowserHidden = false { didSet { UserDefaults.standard.set(showBrowserHidden, forKey: "lume.showBrowserHidden") } }
    // init():
    showPinnedHidden = UserDefaults.standard.bool(forKey: "lume.showPinnedHidden")
    showBrowserHidden = UserDefaults.standard.bool(forKey: "lume.showBrowserHidden")
    ```
  - `var store: LibraryStore? { libraryContext.map { LibraryStore(context: $0) } }` (line 343).
  - `@ObservationIgnored var libraryContext: ModelContext?` (line 57) — injected in `ContentView.onAppear`.

- **`LibraryStore`** (`Sources/LumeCore/Library/LibraryStore.swift`), `@MainActor public final class`:
  - `public func setMeta(path: String, info: String, tagNames: [String], displayName: String = "")` (line 109) — upserts `FileMeta`, sets `info`/`displayName`, resolves tag names to `Tag`s (creating with a cycling color), saves, then `pruneOrphanTags()`.
  - `public func meta(for path: String) -> FileMeta?` (line 130).
  - `public func displayName(for path: String) -> String?` (line 158) — returns nil when empty.
  - `public func files(taggedWith name: String) -> [FileMeta]` (line 163).
  - `public func paths(taggedWith name: String) -> Set<String>` (line 169).
  - `public func allTags() -> [Tag]` (line 176) — sorted by name.
  - `public func colorIndex(forTagNamed name: String) -> Int` (line 191).
  - `public func recolorTag(named name: String, colorIndex: Int)` (line 196) — wraps the index.
  - `public func deleteTag(named name: String)`, `@discardableResult public func pruneOrphanTags() -> Int`, `@discardableResult public func renameTag(named:to:) -> Bool` (not used by Phase A but present).

- **Models** (`Sources/LumeCore/Library/Models.swift`):
  - `@Model public final class Tag { @Attribute(.unique) public var name: String; public var colorIndex: Int = 0; public var files: [FileMeta] }`.
  - `@Model public final class FileMeta { @Attribute(.unique) public var path: String; public var info: String; public var displayName: String; public var hidden: Bool = false; @Relationship(inverse: \Tag.files) public var tags: [Tag] }`.

- **`TagChip`** (`Sources/LumeApp/Sidebar/TagChip.swift`):
  ```swift
  struct TagChip: View {
      let name: String
      let colorIndex: Int
      var onRemove: (() -> Void)? = nil          // ✕ button shown when non-nil
      var onRecolor: ((Int) -> Void)? = nil      // dot → TagSwatchPicker popover when non-nil
  }
  ```
  Plus a free function `func tagColor(_ index: Int) -> Color` and `struct TagSwatchPicker: View { var current: Int; let onPick: (Int) -> Void }` — both declared in the SAME file (`TagChip.swift`). There is **no** separate `TagSwatchPicker.swift` and **no** `TagPalette` in `Sources/LumeApp/Sidebar/` (the spec's parenthetical is slightly off — `TagPalette` lives in `Sources/LumeCore/Library/TagPalette.swift`, a `public enum` with `static var count`, `static func wrap(_:)`, `static func swatch(at:)`).

- **`TagField`** (`Sources/LumeApp/Sidebar/TagField.swift`): `struct TagField` + `struct FlowLayout: Layout` (the wrapping layout — reuse `FlowLayout` for chip rows in the header).

- **The canonical per-file read/write pattern** (from `RowMetaView` in `Sources/LumeApp/Sidebar/FileTreeView.swift:366-494`):
  - `@Query private var allTags: [Tag]` for live colors; `colorIndex(_ name:) = allTags.first { $0.name == name }?.colorIndex ?? 0`.
  - load: `LibraryStore(context: context).meta(for: url.path)?.tags.map(\.name)`.
  - save: `store.setMeta(path: url.path, info: notes, tagNames: tagNames, displayName: store.displayName(for: url.path) ?? "")`.
  - recolor: `LibraryStore(context: context).recolorTag(named: name, colorIndex: idx)`.

- **`DocumentSurfaceView`** (`Sources/LumeApp/Document/DocumentSurfaceView.swift:10-21`): current body is a `Group` that renders `viewer(for:kind:).id(url)` or `emptyState`.

- **`ContentView`** (`Sources/LumeApp/ContentView.swift:21-39`): `.toolbar { ToolbarItemGroup { … } }` holds Open Folder + Favorite buttons. The 🏷 toggle goes here.

- **Test pattern** (`Tests/LumeCoreTests/TagStoreTests.swift:5-12`): `import Testing` + `@testable import LumeCore`; in-memory `ModelContainer(for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`; `@MainActor @Test func …`; retain the container with `defer { withExtendedLifetime(container) {} }`.

---

## File Structure

| File | New / Modify | Responsibility |
|------|--------------|----------------|
| `Sources/LumeCore/Library/TagSuggest.swift` | **New** | Pure, view-free helper `TagSuggest.suggestions(query:names:)` → prefix-filtered, deduped, ordered tag-name suggestions. Unit-tested. |
| `Sources/LumeApp/AppModel.swift` | Modify (lines ~34–37 add property; ~63–64 add init read) | Add `var showEditorTags` flag persisted to `UserDefaults` key `lume.showEditorTags` (default `true`). |
| `Sources/LumeApp/Document/TagAddPopover.swift` | **New** | The "+ add tag" popover: text field that prefix-filters existing tags (with file counts) + a "Create '<x>'" row. Calls back with the chosen/created name. |
| `Sources/LumeApp/Document/DocumentTagHeader.swift` | **New** | The header strip: filename + parent path, removable/recolorable tag chips, "+ add tag" (`TagAddPopover`), a real 🗒 notes affordance (opens `DocumentNotesPopover`, defined in the same file), and the ⌃ collapse control. Reads/writes via `LibraryStore` (`meta(for:)` + `setMeta`). |
| `Sources/LumeApp/Document/DocumentSurfaceView.swift` | Modify (lines 10–21) | Wrap the routed viewer in a `VStack(spacing: 0)`; conditionally render `DocumentTagHeader` above it when `model.showEditorTags`. Preserve `.id(url)`. |
| `Sources/LumeApp/ContentView.swift` | Modify (toolbar, lines 21–39) | Add the 🏷 Tags toggle button to the toolbar, bound to `model.showEditorTags`. |
| `Tests/LumeCoreTests/TagSuggestTests.swift` | **New** | Unit tests for `TagSuggest.suggestions`. |

**Build order (dependency-correct):**
1. Task 1 — `AppModel.showEditorTags` flag (no UI deps; smallest).
2. Task 2 — `TagSuggest` helper + tests (pure logic; used by Task 3).
3. Task 3 — `TagAddPopover` view (depends on `TagSuggest`).
4. Task 4 — `DocumentTagHeader` view (depends on `TagAddPopover`).
5. Task 5 — `DocumentSurfaceView` wrap (depends on `DocumentTagHeader` + the flag).
6. Task 6 — `ContentView` toolbar toggle (depends on the flag; closes the loop).

---

## Task 1: `AppModel.showEditorTags` flag + UserDefaults persistence

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift:34-37` (add property next to the other show* flags) and `Sources/LumeApp/AppModel.swift:63-64` (read it in `init()`)
- Test: build-only (the `@Observable`/`UserDefaults` flag is verified by build + the Task 6 manual check)

- [ ] **Step 1: Add the persisted property**

In `Sources/LumeApp/AppModel.swift`, immediately after the `showBrowserHidden` property (currently line 37), add:

```swift
    /// Pillar ①: when true, the document pane shows the collapsible tag header
    /// above the routed viewer. Persisted globally and remembered across launches
    /// (default true). Toggled by the 🏷 toolbar button and the header's ⌃ collapse.
    var showEditorTags = true { didSet { UserDefaults.standard.set(showEditorTags, forKey: "lume.showEditorTags") } }
```

- [ ] **Step 2: Read it in `init()` (default true when never set)**

`UserDefaults.bool(forKey:)` returns `false` for a missing key, but the default must be `true`. In `init()`, after the line `showBrowserHidden = UserDefaults.standard.bool(forKey: "lume.showBrowserHidden")` (currently line 64), add:

```swift
        // Default to shown on first run: only override the `true` default when a
        // value was explicitly persisted (object(forKey:) is nil when unset).
        if UserDefaults.standard.object(forKey: "lume.showEditorTags") != nil {
            showEditorTags = UserDefaults.standard.bool(forKey: "lume.showEditorTags")
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd /Users/manu/Developer/lume && swift build`
Expected: `Build complete!` (no errors). If the toolchain isn't found, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- [ ] **Step 4: Commit**

```bash
cd /Users/manu/Developer/lume
git add Sources/LumeApp/AppModel.swift
git commit -m "feat(editor-tags): add AppModel.showEditorTags flag (persisted, default true)"
```

---

## Task 2: `TagSuggest` pure helper + unit tests

The add-tag popover filters existing tag names by prefix, drops the current draft's exact duplicate from the "create" decision, and avoids suggesting tags already on the file. Extracting this as a pure function keeps it testable.

**Files:**
- Create: `Sources/LumeCore/Library/TagSuggest.swift`
- Test: `Tests/LumeCoreTests/TagSuggestTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/TagSuggestTests.swift`:

```swift
import Testing
@testable import LumeCore

/// Wrapped in an explicit `@Suite struct` so `swift test --filter TagSuggestTests`
/// matches the SUITE by name. Free `@Test` functions only expose their own symbol
/// names to `--filter`, so a `--filter TagSuggestTests` against free functions can
/// silently match zero tests and pass vacuously (false green). The suite name gives
/// the gate a stable, non-empty target.
@Suite struct TagSuggestTests {

    @Test func emptyQueryReturnsAllSortedExcludingExisting() {
        let out = TagSuggest.suggestions(
            query: "",
            allNames: ["zebra", "apple", "work"],
            existingOnFile: ["work"]
        )
        #expect(out == ["apple", "zebra"])   // sorted, "work" excluded (already on file)
    }

    @Test func prefixFilterIsCaseInsensitive() {
        let out = TagSuggest.suggestions(
            query: "Wo",
            allNames: ["work", "world", "home"],
            existingOnFile: []
        )
        #expect(out == ["work", "world"])
    }

    @Test func draftIsTrimmedBeforeMatching() {
        let out = TagSuggest.suggestions(
            query: "  wo  ",
            allNames: ["work", "home"],
            existingOnFile: []
        )
        #expect(out == ["work"])
    }

    @Test func suggestionsAreDedupedAndExcludeFileTags() {
        let out = TagSuggest.suggestions(
            query: "a",
            allNames: ["alpha", "alpha", "apple", "beta"],
            existingOnFile: ["apple"]
        )
        #expect(out == ["alpha"])   // deduped; "apple" excluded; "beta" filtered out by prefix
    }

    @Test func shouldOfferCreateWhenDraftIsNovel() {
        #expect(TagSuggest.shouldOfferCreate(query: "fresh", allNames: ["work"], existingOnFile: []) == true)
    }

    @Test func shouldNotOfferCreateForBlankOrExisting() {
        #expect(TagSuggest.shouldOfferCreate(query: "   ", allNames: [], existingOnFile: []) == false)
        #expect(TagSuggest.shouldOfferCreate(query: "Work", allNames: ["work"], existingOnFile: []) == false) // case-insensitive existing
        #expect(TagSuggest.shouldOfferCreate(query: "done", allNames: [], existingOnFile: ["done"]) == false) // already on file
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/manu/Developer/lume && swift test --filter TagSuggestTests`
Expected: FAIL — compile error `cannot find 'TagSuggest' in scope` (the type doesn't exist yet). (The `--filter` targets the `@Suite struct TagSuggestTests` by name, so once it compiles it will select all six tests rather than matching nothing.)

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/LumeCore/Library/TagSuggest.swift`:

```swift
import Foundation

/// Pure, view-free autocomplete math for the editor's "+ add tag" popover.
/// Lives in LumeCore so it can be unit-tested without any SwiftUI/SwiftData
/// dependency. Names are matched case-insensitively by prefix; tags already on
/// the file are never suggested (no point re-adding them).
public enum TagSuggest {

    /// Existing tag names to offer, given the current draft text.
    /// - Prefix-filtered (case-insensitive) by the trimmed `query` (empty query = all).
    /// - Excludes any name already on the file (case-insensitive).
    /// - Deduplicated and sorted case-insensitively.
    public static func suggestions(
        query: String,
        allNames: [String],
        existingOnFile: [String]
    ) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let onFile = Set(existingOnFile.map { $0.lowercased() })
        var seen = Set<String>()
        let filtered = allNames.filter { name in
            let lower = name.lowercased()
            guard !onFile.contains(lower) else { return false }
            guard q.isEmpty || lower.hasPrefix(q) else { return false }
            return seen.insert(lower).inserted
        }
        return filtered.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Whether to show a "Create '<draft>'" row: the draft is non-blank, and not
    /// already an existing tag name or already on the file (both case-insensitive).
    public static func shouldOfferCreate(
        query: String,
        allNames: [String],
        existingOnFile: [String]
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let lower = q.lowercased()
        if allNames.contains(where: { $0.lowercased() == lower }) { return false }
        if existingOnFile.contains(where: { $0.lowercased() == lower }) { return false }
        return true
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/manu/Developer/lume && swift test --filter TagSuggestTests`
Expected: PASS, and the summary must report a **non-zero** count — `Suite TagSuggestTests passed` with **6 tests** (`emptyQueryReturnsAllSortedExcludingExisting`, `prefixFilterIsCaseInsensitive`, `draftIsTrimmedBeforeMatching`, `suggestionsAreDedupedAndExcludeFileTags`, `shouldOfferCreateWhenDraftIsNovel`, `shouldNotOfferCreateForBlankOrExisting`). If the run reports `0 tests` / "no tests matched", the gate has NOT passed — the `--filter` name must match the suite. Do not proceed on a zero-count result.

- [ ] **Step 5: Commit**

```bash
cd /Users/manu/Developer/lume
git add Sources/LumeCore/Library/TagSuggest.swift Tests/LumeCoreTests/TagSuggestTests.swift
git commit -m "feat(editor-tags): add TagSuggest autocomplete helper + unit tests"
```

---

## Task 3: `TagAddPopover` view

The popover shown by the header's "+ add tag" button. A focused text field filters existing tags by prefix (showing each tag's file count from `LibraryStore.files(taggedWith:)`); clicking a suggestion or the "Create '<x>'" row calls `onPick(name)`. Live tag list comes from `@Query`; counts come from the store.

**Files:**
- Create: `Sources/LumeApp/Document/TagAddPopover.swift`
- Test: build-only + manual checklist embedded in Task 4 (the popover is exercised through the header)

- [ ] **Step 1: Create the view**

Create `Sources/LumeApp/Document/TagAddPopover.swift`:

```swift
import SwiftUI
import SwiftData
import LumeCore

/// Content of the editor header's "+ add tag" popover. A focused text field
/// prefix-filters existing tags (with their file counts) and offers a
/// "Create '<draft>'" row for novel names. Picking or creating calls `onPick`
/// with the chosen name; the parent is responsible for persisting it onto the
/// file (so this view stays pure and reusable).
struct TagAddPopover: View {
    /// Names already on the file — excluded from suggestions, and used to decide
    /// whether "Create" should appear.
    let existingOnFile: [String]
    /// Called with the chosen (existing) or created (novel) tag name.
    let onPick: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var allNames: [String] { allTags.map(\.name) }

    private var suggestions: [String] {
        TagSuggest.suggestions(query: draft, allNames: allNames, existingOnFile: existingOnFile)
    }

    private var offersCreate: Bool {
        TagSuggest.shouldOfferCreate(query: draft, allNames: allNames, existingOnFile: existingOnFile)
    }

    /// File count for a tag name, via the store (reactive enough — the popover is
    /// short-lived and reopens fresh).
    private func count(_ name: String) -> Int {
        LibraryStore(context: context).files(taggedWith: name).count
    }

    private func pick(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPick(trimmed)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add tag…", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .padding(8)
                .onSubmit {
                    // Return commits the top suggestion, else creates the draft.
                    if let first = suggestions.first { pick(first) }
                    else if offersCreate { pick(draft) }
                }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { name in
                        Button { pick(name) } label: {
                            HStack(spacing: 6) {
                                TagChip(name: name, colorIndex: colorIndex(name))
                                Spacer()
                                Text("\(count(name))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if offersCreate {
                        if !suggestions.isEmpty { Divider() }
                        Button { pick(draft) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.secondary)
                                Text("Create “\(draft.trimmingCharacters(in: .whitespacesAndNewlines))”")
                                    .font(.callout)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if suggestions.isEmpty && !offersCreate {
                        Text(draft.isEmpty ? "No tags yet — type to create one."
                                           : "Already on this file.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 240)
        .onAppear { focused = true }
    }

    /// Live color for a name from the reactive @Query (0 until first saved).
    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/manu/Developer/lume && swift build`
Expected: `Build complete!` (no errors). The view isn't referenced yet; this confirms `TagChip`, `tagColor`, `@Query(sort:)`, and `LibraryStore.files(taggedWith:)` all resolve.

- [ ] **Step 3: Commit**

```bash
cd /Users/manu/Developer/lume
git add Sources/LumeApp/Document/TagAddPopover.swift
git commit -m "feat(editor-tags): add TagAddPopover (prefix autocomplete + create row)"
```

---

## Task 4: `DocumentTagHeader` view

The header strip rendered above the routed viewer. Left: filename + faint parent path. Center: removable/recolorable tag chips (reusing `TagChip` + `FlowLayout`). A "+ add tag" button presents `TagAddPopover`. Right: a 🗒 notes affordance that opens a real `.popover` containing a `TextEditor` bound to the file's notes, and a ⌃ collapse control that sets `model.showEditorTags = false`.

> **Notes affordance — real, not a no-op.** The spec (line 36) calls the notes affordance "optional," and `model.notesOpenPath` is only read by `RowMetaView` in the *sidebar* (grep confirms no reader under `Sources/LumeApp/Document/`), so toggling it from the document header would be a visible no-op. Instead, the 🗒 button here opens a small in-header notes popover (`DocumentNotesPopover`) with a `TextEditor` whose contents are the file's notes — loaded from `meta(for:)?.info` and saved through the **same** `setMeta(path:info:tagNames:displayName:)` path the header already uses (writing the edited notes into `info` while preserving the current `tagNames` and `displayName`). This keeps it scoped and simple while making the button do something real.

All persistence reads existing meta first and writes through `setMeta`, preserving `info` (notes), `tagNames`, and `displayName` as appropriate.

**Files:**
- Create: `Sources/LumeApp/Document/DocumentTagHeader.swift`
- Test: `swift build` + manual checklist (Step 3)

- [ ] **Step 1: Create the view**

Create `Sources/LumeApp/Document/DocumentTagHeader.swift`:

```swift
import SwiftUI
import SwiftData
import LumeCore

/// Pillar ①: the collapsible tag header at the top of the document pane. Shared
/// across all file types (markdown, code, env, pdf, html, quicklook). Renders the
/// selected file's tags as removable/recolorable chips and an "+ add tag"
/// autocomplete popover. Persists through `LibraryStore.setMeta`, preserving the
/// file's existing `info` (notes) and `displayName`. Orphan pruning runs inside
/// `setMeta`, so removing a tag's last file auto-cleans the vocabulary.
struct DocumentTagHeader: View {
    let url: URL
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var tagNames: [String] = []
    @State private var loaded = false
    @State private var addingTag = false
    @State private var showingNotes = false

    /// Live color for a tag name from the reactive @Query (0 until first saved).
    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }

    private var parentPath: String {
        url.deletingLastPathComponent().path
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Left: filename + faint parent path.
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(parentPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .layoutPriority(1)

            // Center: chips + add control.
            FlowLayout(spacing: 6) {
                ForEach(tagNames, id: \.self) { name in
                    TagChip(name: name,
                            colorIndex: colorIndex(name),
                            onRemove: { remove(name) },
                            onRecolor: { idx in recolor(name, idx) })
                }
                addButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: notes + collapse.
            HStack(spacing: 8) {
                Button {
                    showingNotes.toggle()
                } label: {
                    Image(systemName: "note.text")
                }
                .buttonStyle(.borderless)
                .help("Notes")
                .popover(isPresented: $showingNotes, arrowEdge: .bottom) {
                    DocumentNotesPopover(url: url)
                }

                Button {
                    model.showEditorTags = false
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Hide tag header")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in loaded = false; load() }
    }

    private var addButton: some View {
        Button { addingTag = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                Text("add tag")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .help("Add a tag")
        .popover(isPresented: $addingTag, arrowEdge: .bottom) {
            TagAddPopover(existingOnFile: tagNames) { name in
                add(name)
            }
        }
    }

    // MARK: Data

    private func load() {
        guard !loaded else { return }
        let store = LibraryStore(context: context)
        tagNames = store.meta(for: url.path)?.tags.map(\.name) ?? []
        loaded = true
    }

    /// Persist the current `tagNames`, preserving the file's existing notes/info
    /// and displayName (spec requirement: never clobber them).
    private func persist() {
        let store = LibraryStore(context: context)
        let existing = store.meta(for: url.path)
        store.setMeta(path: url.path,
                      info: existing?.info ?? "",
                      tagNames: tagNames,
                      displayName: existing?.displayName ?? "")
    }

    private func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        tagNames.append(trimmed)
        persist()
    }

    private func remove(_ name: String) {
        tagNames.removeAll { $0 == name }
        persist()   // setMeta auto-prunes the tag if this was its last file
    }

    private func recolor(_ name: String, _ idx: Int) {
        // Make sure the tag exists in the store before recoloring (a just-added
        // tag is already persisted by `add`, but be defensive).
        persist()
        LibraryStore(context: context).recolorTag(named: name, colorIndex: idx)
    }
}

/// A minimal per-file notes popover opened by the header's 🗒 button. Loads the
/// file's notes from `FileMeta.info` (via `LibraryStore.meta(for:)`) and saves
/// edits through the SAME `setMeta(path:info:tagNames:displayName:)` path the
/// header uses — writing the edited notes into `info` while preserving the
/// file's existing `tagNames` and `displayName`, so notes and tags never clobber
/// each other. Scoped and simple by design: a focused `TextEditor` plus an
/// explicit Save. Persisting through `setMeta` keeps the reactive @Query-backed
/// chips and the sidebar in sync (and runs the usual orphan prune).
struct DocumentNotesPopover: View {
    let url: URL

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.callout)
                .focused($focused)
                .frame(width: 280, height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )
            HStack {
                Spacer()
                Button("Done") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        notes = LibraryStore(context: context).meta(for: url.path)?.info ?? ""
        loaded = true
    }

    /// Save the edited notes into `info`, preserving the file's existing tags and
    /// displayName (read fresh so a tag added while the popover was open isn't lost).
    private func save() {
        let store = LibraryStore(context: context)
        let existing = store.meta(for: url.path)
        store.setMeta(path: url.path,
                      info: notes,
                      tagNames: existing?.tags.map(\.name) ?? [],
                      displayName: existing?.displayName ?? "")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/manu/Developer/lume && swift build`
Expected: `Build complete!`. Confirms `TagAddPopover`, `TagChip`, `FlowLayout`, `DocumentNotesPopover`, `model.showEditorTags`, and the `LibraryStore` calls (`meta(for:)`, `setMeta`, `recolorTag`) all resolve. (The header isn't wired into the surface yet — that's Task 5.)

- [ ] **Step 3: Commit (manual verification happens after Task 5, when it's visible)**

```bash
cd /Users/manu/Developer/lume
git add Sources/LumeApp/Document/DocumentTagHeader.swift
git commit -m "feat(editor-tags): add DocumentTagHeader (chips, add/remove/recolor, collapse)"
```

---

## Task 5: Wrap the viewer in `DocumentSurfaceView`

Render `DocumentTagHeader` above the routed viewer when `model.showEditorTags`, inside a `VStack(spacing: 0)`, preserving the `.id(url)` rebuild on the viewer. Hidden state contributes zero height.

**Files:**
- Modify: `Sources/LumeApp/Document/DocumentSurfaceView.swift:10-21`
- Test: `swift build` + manual checklist (Step 3)

- [ ] **Step 1: Replace the `body`'s `Group`**

In `Sources/LumeApp/Document/DocumentSurfaceView.swift`, replace the current `body` (lines 10–21):

```swift
    var body: some View {
        Group {
            if let url = model.selectedFile, let kind = model.selectedKind {
                viewer(for: url, kind: kind)
                    .id(url) // rebuild the surface when the selection changes
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
```

with:

```swift
    var body: some View {
        Group {
            if let url = model.selectedFile, let kind = model.selectedKind {
                VStack(spacing: 0) {
                    if model.showEditorTags {
                        DocumentTagHeader(url: url, model: model)
                    }
                    viewer(for: url, kind: kind)
                        .id(url) // rebuild the surface when the selection changes
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/manu/Developer/lume && swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Manual verification**

Build and run the app against a real folder:

```bash
cd /Users/manu/Developer/lume
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./tools/build-app.sh
LUME_OPEN_FOLDER="$HOME/Developer/lume/Sources" \
LUME_OPEN_FILE="$HOME/Developer/lume/Sources/LumeApp/ContentView.swift" \
open -n /Applications/Lume.app   # or: open -n dist/Lume.app
```

(If `/Applications` wasn't writable, the script installs to `~/Applications/Lume.app` — open that instead, or just `open -n dist/Lume.app`.)

Confirm:
- [ ] The header strip appears at the top of the document pane, above the viewer, showing `ContentView.swift` and the parent path.
- [ ] The header renders identically for other file types: select a `.md` (markdown editor), an `.env` if present, a `.pdf`, an image (Quick Look). Header is always above the viewer.
- [ ] Click **+ add tag** → popover opens, text field is focused; type `wo` → suggestions filter; pick or create a tag → it appears as a chip in the header.
- [ ] Add a second tag; remove the first via its ✕ → chip disappears; if it was that tag's only file, it is gone from the sidebar Tags section too (auto-prune).
- [ ] Click a chip's color dot → `TagSwatchPicker` popover; pick a color → chip recolors, and the same tag recolors live in the sidebar.
- [ ] Click the ⌃ (chevron.up) collapse control → header disappears, viewer takes full height.
- [ ] Click 🗒 → a notes popover opens with a focused `TextEditor`; type some notes, click **Done** → reopen the popover and confirm the text persisted. Confirm adding/removing a tag afterward does NOT wipe the notes (and editing notes does NOT wipe the tags) — both round-trip through `setMeta` preserving the other.
- [ ] Switch to a different file in the sidebar → header updates to the new file's name/path/tags immediately.

- [ ] **Step 4: Commit**

```bash
cd /Users/manu/Developer/lume
git add Sources/LumeApp/Document/DocumentSurfaceView.swift
git commit -m "feat(editor-tags): wrap viewer with DocumentTagHeader in DocumentSurfaceView"
```

---

## Task 6: `ContentView` toolbar 🏷 Tags toggle

A global toolbar button that toggles `model.showEditorTags`. Closes the loop: the ⌃ in the header hides; this button shows it again (and remembers the choice via the flag's `didSet` persistence from Task 1).

**Files:**
- Modify: `Sources/LumeApp/ContentView.swift:21-39` (inside the existing `ToolbarItemGroup`)
- Test: `swift build` + manual checklist (Step 3)

- [ ] **Step 1: Add the toggle button**

In `Sources/LumeApp/ContentView.swift`, inside the existing `ToolbarItemGroup` (after the Favorite button's closing `}` on line 37, before the group's closing `}` on line 38), add:

```swift
                Button {
                    model.showEditorTags.toggle()
                } label: {
                    Label("Tags", systemImage: model.showEditorTags ? "tag.fill" : "tag")
                }
                .help(model.showEditorTags ? "Hide the document tag header" : "Show the document tag header")
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/manu/Developer/lume && swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Manual verification**

```bash
cd /Users/manu/Developer/lume
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./tools/build-app.sh
LUME_OPEN_FOLDER="$HOME/Developer/lume/Sources" \
LUME_OPEN_FILE="$HOME/Developer/lume/Sources/LumeApp/ContentView.swift" \
open -n /Applications/Lume.app   # or: open -n dist/Lume.app
```

Confirm:
- [ ] A 🏷 Tags button appears in the toolbar; its icon is `tag.fill` when the header is shown, `tag` when hidden.
- [ ] Clicking it hides/shows the header (mirrors the ⌃ collapse control in the header).
- [ ] Collapse via the header's ⌃ → toolbar icon flips to `tag` (single source of truth: both drive `showEditorTags`).
- [ ] Quit and relaunch the app: the last header visibility state is remembered (persistence works). Verify both directions — hide, relaunch (stays hidden); show, relaunch (stays shown).
- [ ] Default state on a fresh install (or after `defaults delete <app-bundle-id> lume.showEditorTags` then relaunch): header is **shown** (default true).

- [ ] **Step 4: Commit**

```bash
cd /Users/manu/Developer/lume
git add Sources/LumeApp/ContentView.swift
git commit -m "feat(editor-tags): add 🏷 Tags toolbar toggle for the editor header"
```

---

## Final regression check

- [ ] **Run the full test suite** to confirm no existing tests broke (tag store, palette, copy-paths, etc.):

  Run: `cd /Users/manu/Developer/lume && swift test`
  Expected: all tests pass, including the existing `TagStoreTests`, `TagPaletteTests`, `LibraryStoreTests` and the new `TagSuggestTests`.

- [ ] **Clean release build of the bundle**:

  Run: `cd /Users/manu/Developer/lume && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./tools/build-app.sh`
  Expected: the app bundle builds with no errors and prints `✓ Built …/dist/Lume.app` and `✓ Installed to /Applications/Lume.app`.

---

## Self-Review

**1. Spec coverage (Pillar ① requirements → task):**

| Spec requirement (lines 26–53) | Task |
|---|---|
| `DocumentTagHeader` renders for `model.selectedFile` | Task 4 (+ Task 5 wiring) |
| Left: filename (`url.lastPathComponent`) + faint parent path | Task 4 (`url.lastPathComponent` + `deletingLastPathComponent().path`) |
| Chips reactive via `@Query private var allTags: [Tag]`, colors live | Task 4 (`@Query(sort: \Tag.name)`, `colorIndex(_:)`) |
| Each chip `TagChip` with `onRemove` (✕) and `onRecolor` (dot → `TagSwatchPicker`) | Task 4 (`TagChip(... onRemove: onRecolor:)`; `TagSwatchPicker` is opened inside `TagChip` itself) |
| "+ add tag" → popover filtering existing tags by prefix with file counts + "Create '<x>'" row | Task 3 (`TagAddPopover` using `TagSuggest`, counts via `LibraryStore.files(taggedWith:)`) |
| Picking/creating adds the tag to the file | Task 4 (`add(_:)` → `persist()`) |
| Right: notes affordance (🗒) + ⌃ collapse | Task 4 (🗒 opens `DocumentNotesPopover` — a real `TextEditor` bound to `FileMeta.info`, saved via `setMeta` preserving tags/displayName; ⌃ = `chevron.up` sets `showEditorTags = false`) |
| Persistence via `setMeta(path:info:tagNames:displayName:)` preserving existing info/displayName | Task 4 (`persist()` reads `existing?.info`/`existing?.displayName`) |
| Recolor via `recolorTag` | Task 4 (`recolor(_:_:)`) |
| Orphan pruning runs in `setMeta` | Verified (no extra code; `setMeta` calls `pruneOrphanTags()`); covered by Task 5 manual check |
| `DocumentSurfaceView` wraps viewer in `VStack(spacing:0)` with `if model.showEditorTags`, keep `.id(url)` | Task 5 |
| `AppModel.showEditorTags: Bool`, `UserDefaults` key `lume.showEditorTags`, default `true`, follows show* pattern | Task 1 |
| Toolbar 🏷 Tags toggle in `ContentView` (global, remembered) | Task 6 |
| ⌃ collapse in the header sets the same flag | Task 4 (`showEditorTags = false`) + Task 6 (manual cross-check) |
| Always reflects open file's tags the moment it opens | Task 4 (`onAppear` load + `onChange(of: url)` reload) + Task 5 manual check |
| Hidden state contributes zero height | Task 5 (`if model.showEditorTags` — no view, no height) |

No gaps. Every Pillar ① bullet maps to a task.

**2. Placeholder scan:** No "TBD"/"TODO"/"similar to Task N"/"add error handling" placeholders. Every code step shows complete Swift. Manual-verification steps list concrete, checkable items.

**3. Type/signature consistency (cross-task):**
- `TagSuggest.suggestions(query:allNames:existingOnFile:)` and `TagSuggest.shouldOfferCreate(query:allNames:existingOnFile:)` — defined identically in Task 2, called identically in Task 3. ✓
- `TagAddPopover(existingOnFile:onPick:)` — defined Task 3, called in Task 4 with `existingOnFile: tagNames` and an `onPick` closure. ✓
- `DocumentTagHeader(url:model:)` — defined Task 4, called in Task 5 as `DocumentTagHeader(url: url, model: model)`. ✓
- `DocumentNotesPopover(url:)` — defined Task 4 (same file as `DocumentTagHeader`), presented from the header's 🗒 `.popover`. Loads via `meta(for:)?.info`, saves via `setMeta(...)` preserving the file's existing `tagNames`/`displayName`. No reliance on `model.notesOpenPath` (which only the sidebar reads), so the button is a real action, not a no-op. ✓
- `model.showEditorTags` — declared Task 1, read in Task 4 (set false), Task 5 (`if`), Task 6 (`toggle()`/icon). ✓
- `TagChip(name:colorIndex:onRemove:onRecolor:)` — matches the real signature in `TagChip.swift` (`onRecolor: ((Int) -> Void)?`). ✓
- `LibraryStore.setMeta(path:info:tagNames:displayName:)`, `.meta(for:)`, `.recolorTag(named:colorIndex:)`, `.files(taggedWith:)`, `.displayName(for:)` — all match the verified `LibraryStore` signatures. ✓
- `FlowLayout(spacing:)` reused from `TagField.swift` (same module, `internal`). ✓

**Codebase mismatches vs. the spec (flagged for the implementer):**
1. The spec (line 20) lists `TagPalette` among `Sources/LumeApp/Sidebar/` components. It is actually `Sources/LumeCore/Library/TagPalette.swift` (a `public enum`). Not used directly by Phase A (it's reached transitively via `tagColor`/`TagChip`), so this has no impact, but don't look for it under `Sidebar/`.
2. The spec (line 20) lists `TagSwatchPicker` as a standalone reusable component. It is declared **inside** `TagChip.swift`, not in its own file. Phase A never constructs `TagSwatchPicker` directly — `TagChip`'s `onRecolor` opens it internally — so the header just passes `onRecolor:` and gets the swatch popover for free.
3. The spec phrases recolor as "recolor via `recolorTag`". `TagChip.onRecolor` delivers a new `Int` index; the header forwards it to `LibraryStore.recolorTag(named:colorIndex:)`. Confirmed this matches `RowMetaView.recolor` exactly. ✓
4. `UserDefaults.bool(forKey:)` returns `false` for unset keys, which would invert the spec's `true` default. Task 1 Step 2 handles this with an `object(forKey:) != nil` guard — the only deviation from the literal `showPinnedHidden` pattern, and a necessary one.
5. **TagSuggest tests are wrapped in `@Suite struct TagSuggestTests`** (not free `@Test` functions) so `swift test --filter TagSuggestTests` matches the suite name and selects all six tests. With free functions, `--filter TagSuggestTests` could match nothing and pass vacuously (false green). The Task 2 run-command expectations explicitly require a non-zero test count and forbid proceeding on a `0 tests` result.
