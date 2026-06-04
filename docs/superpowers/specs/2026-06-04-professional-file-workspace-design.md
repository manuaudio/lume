# Professional File Workspace — Design Spec

**Date:** 2026-06-04
**Status:** Approved in brainstorming (visual companion). Ready for implementation planning.
**Scope:** Three related pillars, designed as one cohesive redesign, **built in three phases**. Each phase gets its own implementation plan.

## Goal

Turn Lume's file management into something that feels like a professional, Finder-grade workspace. The basic functionality (open, view, tag, favorite) exists; the magic is in usability — fast native selection, tags surfaced where you actually read files, and effortless tag filtering/curation.

## The Three Pillars

1. **Tags in the document editor** — a collapsible tag header at the top of the open file.
2. **Finder-feel sidebar selection** — native ⌘/⇧ multi-select, disclosure triangles, keyboard nav, and a bulk action bar — identical in **both** the FAVORITES (pinned) and OPEN FOLDER (Browse) regions.
3. **Tag filtering & management** — multi-tag All/Any filtering plus a Manage Tags panel (rename / recolor / merge / delete).

## Cross-Cutting Principles

- **One consistent interaction layer across both sidebar regions.** Whatever works in FAVORITES works identically in OPEN FOLDER (Browse): selection mechanics, triangles, keyboard, action bar. Only the *contextual actions* differ (Pin vs Unpin, Open Folder, Hide curation).
- **Reuse what Phase-1 tags already shipped:** `TagPalette`, `TagChip`, `TagSwatchPicker`, `TagField` (`Sources/LumeApp/Sidebar/`), and `LibraryStore` tag ops (`recolorTag`, `deleteTag`, `renameTag` with merge, `pruneOrphanTags`, `colorIndex(forTagNamed:)`, `allTags`).
- **Tags are edited in two clear places, viewed everywhere.** Edit a *file's* tags in the editor header (primary) or the multi-select action bar (bulk). Curate the *tag vocabulary* in the Manage Tags panel. The sidebar shows read-only chips for glanceability.
- **Testing:** pure logic (filter set math, tag merge, path queries) is unit-tested in `Tests/LumeCoreTests/`; SwiftUI views are verified by build + manual checks (the project has no UI test target). Build: `swift build` / app bundle via `tools/build-app.sh`; tests: `swift test` (set `DEVELOPER_DIR` if the toolchain isn't found).

---

## Pillar ① — Tags in the Document Editor

### What it is
A tag header strip at the very top of the document pane, **above** the routed viewer and **shared across all file types** (markdown, code, env, pdf, html, quicklook). Default shown; collapsible to zero height.

### Components & integration
- **`DocumentTagHeader`** (new, `Sources/LumeApp/Document/DocumentTagHeader.swift`): renders for `model.selectedFile`.
  - Left: filename (`url.lastPathComponent`) + faint parent path.
  - Tag chips: reactive (`@Query private var allTags: [Tag]` for live colors; the file's tags from its `FileMeta`). Each chip uses `TagChip` with `onRemove` (✕) and `onRecolor` (dot → `TagSwatchPicker` popover).
  - **"+ add tag"** → a popover (`TagAddPopover`, new) with a text field that filters existing tags by prefix (showing file counts via `allTags` / `LibraryStore.files(taggedWith:)`) and a "Create '<x>'" row. Picking/creating adds the tag to the file. Autocomplete makes reusing tags the path of least resistance (reduces near-duplicates).
  - Right: optional notes affordance (🗒, opens existing notes editing) and a **⌃ collapse** control.
  - Persistence: writes through `LibraryStore.setMeta(path:info:tagNames:displayName:)` preserving the file's existing `info`/`displayName`; recolor via `recolorTag`. Orphan pruning already runs in `setMeta`.
- **`DocumentSurfaceView`** (`Sources/LumeApp/Document/DocumentSurfaceView.swift`, ~lines 10–22): wrap the routed viewer:
  ```
  VStack(spacing: 0) {
      if model.showEditorTags, let url = model.selectedFile { DocumentTagHeader(url: url, model: model) }
      viewer(for: url, kind: kind).id(url)   // keep the .id(url) rebuild
  }
  ```
- **Show/hide state:** `AppModel.showEditorTags: Bool` persisted to `UserDefaults` (`lume.showEditorTags`, default `true`), following the existing `showPinnedHidden`/`showBrowserHidden` pattern.
  - **Toolbar toggle:** a 🏷 Tags button in `ContentView`'s `.toolbar` (global, remembered).
  - **⌃ collapse** in the header sets the same flag.

### Behavior
- Always reflects the open file's tags the moment it opens.
- Add → filter existing or create new. Recolor → chip dot popover. Remove → ✕ (auto-prunes if it was the tag's last file).
- Hidden state contributes zero height; document gets full height.

---

## Pillar ② — Finder-Feel Sidebar Selection

### The core change
Today each row has custom `.onTapGesture(count: 1)` (sets `selectedFile` / toggles folder expand) and `.onTapGesture(count: 2)` (drill). These intercept clicks and **break the List's native ⌘/⇧ multi-select**. The fix: stop overloading single-click and lean on the native `List(selection:)` already wired (rows are `.tag(SidebarRow(...).id)`, selection is `Set<String>` = `model.selectedRowIDs`).

### Interaction model (identical in FAVORITES and Browse)
- **Click** → select one (native). One file selected ⇒ it opens in the editor, driven by the existing `onChange(of: selectedRowIDs) { openIfSingleFileSelected() }`.
- **⌘-click** → toggle a row in/out (non-contiguous multi).
- **⇧-click** → contiguous range from the anchor.
- **Disclosure triangle (▸/▾)** on folder rows → expand/collapse `expandedPaths`. The row *body* selects; the *triangle* expands (Finder semantics). Single-click no longer auto-expands.
- **Double-click folder** → drill in (`model.drillInto` / set browse root). Double-click file → open. (Implementation note: double-click must not re-break native selection — use a non-intercepting mechanism, e.g. `simultaneousGesture(TapGesture(count: 2))` or an AppKit double-click recognizer; the plan's research step resolves the exact approach.)
- **Keyboard** (extends the existing List-scoped key handlers in `SidebarView`): ↑/↓ move, ⇧↑/⇧↓ extend, →/← expand/collapse, ⏎ open, Space Quick Look (exists), ⌘A select all, ⌘C / ⌥⌘C copy paths (exists).

### Bulk action bar
- Appears when `model.selectedRowIDs.count >= 2`, as a slim bar pinned to the **bottom of the sidebar** (`safeAreaInset(edge: .bottom)`).
- Shows the count + contextual bulk actions: **Copy Paths** (`copyPaths`), **Tag…** (opens the bulk tag editor — `MultiTagSheet` / tag popover), **Pin/Unpin**, **Hide/Unhide**. Actions branch on context (e.g., Browse shows Pin + Open Folder; Favorites shows Unpin).

### Consistency requirement
The row view, selection mechanics, triangles, keyboard handling, and action bar are **section-agnostic**; both `FileTreeView` instances (pinned + browser) use them. Region-specific behavior is limited to the *action set* and existing concerns (FAVORITES drag-to-reorder via `.onMove`, Hide curation). 

### Known integration concerns (for the plan)
- **Drag-to-reorder coexistence:** FAVORITES uses `.onMove`; verify native multi-select + reorder coexist (Finder allows multi-drag; at minimum reorder must not regress).
- **Folder expand vs select:** ensure the triangle hit-target doesn't trigger selection, and vice-versa.
- **RowMetaView trigger:** the inline tag chips/editor under a selected file (from Phase-1) must still work with selection-driven opening.

---

## Pillar ③ — Tag Filtering & Management

### Filtering (multi-tag)
- Replace `AppModel.activeTagFilter: String?` with:
  - `activeTagFilters: Set<String>` and `tagFilterMatchAll: Bool` (default **true** = All/AND; toggle to Any/OR).
- **Filter application** (`FileTreeView.visibleChildren`, ~lines 74–78) becomes set-based: allowed paths = **intersection** (All) or **union** (Any) of `store.paths(taggedWith:)` across `activeTagFilters`. Helper(s) on `LibraryStore` (e.g., `paths(taggedWithAll:)` / `paths(taggedWithAny:)`) keep the math testable. Filtering already runs inside `FileTreeView`, so it applies to **both** regions automatically.
- **Active filter bar** (sidebar): shows the active tag chips (removable), the **All/Any** toggle, a match count, and **Clear**. Clicking a tag in the Tags section toggles its membership in `activeTagFilters`.

### Management (Manage Tags panel)
- **`TagManagerSheet`** (new, `Sources/LumeApp/Sidebar/TagManagerSheet.swift`), opened from a **⚙ Manage** control in the Tags section header.
  - Searchable list of all tags; each row: color swatch (recolor via `TagSwatchPicker`), name (inline rename via `renameTag`), file count, and a multi-select checkbox.
  - Footer actions on the checkbox selection: **Merge** (2+ tags → choose the survivor's name + color; consolidates files, deletes the others), **Rename**, **Color**, **Delete**.
- **Merge logic:** reuse/extend the store. `renameTag(named:to:)` already merges on name clash; add `LibraryStore.mergeTags(_ names: [String], into survivor: String, colorIndex: Int?)` that re-points every file onto the survivor, applies the chosen color, and prunes the emptied tags (built on the existing merge + `pruneOrphanTags`). Unit-tested in `Tests/LumeCoreTests/`.

### Division of labor
- Tagging *files* in bulk → Pillar ② action bar ("Tag…").
- Curating the tag *vocabulary* → this panel.
- The sidebar Tags section is both the filter control and the entry point (⚙) to management.

---

## Phased Implementation

Built in three phases (each its own plan); ordered low-risk-win → substrate → tie-together:

- **Phase A — Pillar ① (editor tag header).** Self-contained, reuses Phase-1 components. New `DocumentTagHeader` + `TagAddPopover`, `DocumentSurfaceView` wrap, `showEditorTags` flag + toolbar toggle.
- **Phase B — Pillar ② (Finder-feel selection).** The substrate and the riskiest piece. Remove competing gestures, add disclosure triangles, selection-driven open, double-click drill, keyboard nav, bulk action bar — uniform across both regions. Includes a small research step for the double-click + drag-reorder coexistence.
- **Phase C — Pillar ③ (filtering & management).** Multi-tag filter state + set-based filtering, active filter bar, `TagManagerSheet`, `mergeTags`. Its bulk "Tag…" entry point pairs with Phase B's action bar.

### Dependencies
- Phase C's filter touches state Pillar ② doesn't depend on; Phase B's action bar exposes "Tag…" which can start with the existing `MultiTagSheet` and need not block on Phase C.
- All phases reuse Phase-1 tag components and store ops; no schema migration is required beyond what already shipped (`Tag.colorIndex`).

## Testing Strategy

- **Unit (LumeCoreTests):** `paths(taggedWithAll:)` / `paths(taggedWithAny:)`, `mergeTags(_:into:colorIndex:)`, and any filter-set helpers — with the established in-memory `ModelContainer` pattern (retain the container for the test body).
- **Build + manual:** all SwiftUI surfaces (editor header, selection behavior, action bar, filter bar, manager sheet), verified against a real folder via `tools/build-app.sh` and `LUME_OPEN_FOLDER`.
- **Regression guard:** existing tag tests, copy-paths, hidden/favorite behaviors, and FAVORITES reorder must stay green.
