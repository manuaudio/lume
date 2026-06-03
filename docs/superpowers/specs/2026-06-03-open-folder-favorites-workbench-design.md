# Open Folder & Favorites Workbench — Design

**Date:** 2026-06-03
**Status:** Approved (verbal), ready for implementation plan
**Predecessor:** the current 2-region sidebar (Pinned + Tags + Browser-with-breadcrumb)

## Goal

Turn Lume's sidebar into a focused two-region workbench:

1. A **Favorites** shelf you curate and operate on (multi-select, copy paths,
   hide, tag, open).
2. An **Open Folder** region — the single folder you concentrate on — with the
   always-on breadcrumb replaced by a hold-to-reveal ancestor path.

The deeper purpose: the human curates *their* files (pin folders, drill in,
hide the noise), then selects and **copies the paths** to hand to an LLM later.
The curated, human-touched files are the valuable signal; everything else is
noise the model can deal with on its own. This design delivers the navigation
and curation; the LLM analysis that consumes the copied paths is a **separate,
later milestone**.

## Approved Decisions (from brainstorming)

1. **Two named regions:** `FAVORITES` (curated shelf, folders still drill inline)
   on top; `OPEN FOLDER · <name>` (the focused folder's tree) below. The
   permanent breadcrumb is removed. The `Tags` section is unchanged.
2. **Favorites is a workbench:** multi-select files *and* folders; act on the
   selection via context menu + keyboard — Open, Copy Path(s), Hide, Edit
   Tags…, Rename…, Unpin.
3. **Hide/show curation:** `Hide` sets a persisted per-path flag; hidden items
   disappear from both regions by default. A global **Show hidden** toggle
   reveals them dimmed with an Un-hide affordance.
4. **Copy Paths is the AI hand-off:** newline-joined absolute POSIX pathnames to
   the clipboard (Finder "Copy as Pathname"), via right-click, ⌥⌘C, or drag-out.
   No new "working set" data model — the selection *is* the set.
5. **Open Folder navigation:** an explicit **Open** command promotes a favorite
   folder to the Open Folder; **hold ⌃ (Control)** reveals a clickable ancestor
   path to jump up; release collapses it.
6. **Data:** one additive SwiftData field `FileMeta.hidden`; `showHidden` in
   UserDefaults. No other schema changes.

**Out of scope (later milestone):** feeding copied paths to an LLM to
analyze/improve them.

## Design

### 1. Sidebar regions

`SidebarView` keeps three `Section`s but reframes them:

- **`FAVORITES`** — the existing Pinned section, retitled. Folders keep inline
  expansion (`expandedPaths` + recursive `FileTreeView`). This is the curation
  surface.
- **`TAGS`** — unchanged.
- **`OPEN FOLDER · <name>`** — the existing Browser section, retitled with the
  current `browseRoot`'s display name in the header, and with the always-on
  breadcrumb header removed (replaced by §5). Still renders `browseRoot`'s tree
  via `FileTreeView`; double-clicking a subfolder re-roots (`drillInto`) as it
  does today.

### 2. Multi-selection

Today `List(selection:)` binds a single `String?` (`model.selectedRowID`). To
operate on several rows, selection becomes a **set**.

- `AppModel.selectedRowIDs: Set<String>` replaces the single `selectedRowID`.
  `List(selection:)` binds to this set (SwiftUI `List` supports
  `Set<SelectionValue>` bindings on macOS).
- Existing single-row keyboard handlers (Space = Quick Look, ←/→ = collapse/
  expand) operate on the **sole selected row** — they run only when
  `selectedRowIDs.count == 1`, decoding that one ID exactly as the old
  `selectedRowID` path did, and are no-ops for multi-selection.
- ⌘-click toggles a row; ⇧-click extends a range (native `List` multi-select
  behavior — no custom gesture code needed once the binding is a `Set`).
- Opening a *file* on selection change still applies only when exactly one file
  row is selected (so multi-select doesn't thrash the document view): the
  existing `openIfFile` runs only when `selectedRowIDs.count == 1`.
- `selectedURLs: [URL]` is a computed helper on `AppModel` that decodes the
  selected row IDs (via `SidebarRow.decode`) to file URLs, preserving sidebar
  order. All multi-item commands consume this.

### 3. Row context menu + keyboard commands

`RowMenu` (in `FileTreeView.swift`) operates on the **selection** (falling back
to the right-clicked row if it isn't part of the current selection — standard
macOS behavior). Items:

- **Open** — folders only; `model.drillInto(url)` on the (first) folder. Also
  bound to Return (⏎) and double-click on a folder.
- **Copy Path(s)** — ⌥⌘C; see §4.
- **Hide** / **Un-hide** — ⌘⌫; see §5. Label reflects current state of the
  selection (all hidden → "Un-hide").
- **Edit Tags…** — opens the existing tags/notes editor for the row
  (`notesOpenPath`); for a multi-selection, applies typed tags to **all**
  selected paths (see §6).
- **Rename…** — single selection only (display-name rename, existing
  `RenameField`).
- **Unpin** — removes the selected favorites (`togglePin`/`removeFavorite` per
  path).
- **Reveal in Finder** — unchanged.

Keyboard shortcuts are registered on the sidebar `List` (the existing
`.onKeyPress`/command pattern) and act on `selectedURLs`.

### 4. Copy Paths (AI hand-off)

New pure helper in LumeCore so it is unit-testable and reusable:

`PathExport.clipboardString(for urls: [URL]) -> String`
- Returns the absolute POSIX `path` of each URL, one per line, in the given
  order, joined by `\n`. Empty input → `""`.

App layer (`AppModel.copyPaths()`):
- Writes `PathExport.clipboardString(for: selectedURLs)` to
  `NSPasteboard.general` as `.string`, **and** writes the file URLs
  (`selectedURLs` as `NSURL`s) so a paste into Finder/editors that prefer file
  references still works. (Mirrors Finder's "Copy as Pathname", which puts the
  newline-joined paths on the pasteboard.)

Drag-out: sidebar rows are made draggable so dragging the selection to another
app carries the file URLs (and thus their paths when dropped into a text
field). Implemented with SwiftUI `.draggable`/`onDrag` providing `URL` items for
each selected row.

### 5. Hide / show curation

**Data:** add `var hidden: Bool = false` to `FileMeta` (Models.swift). Additive
property with a default — SwiftData performs a lightweight automatic migration,
no manual migration code. Hidden is keyed by path (a path hidden once is hidden
everywhere it appears).

**Store API (LibraryStore):**
- `func setHidden(_ hidden: Bool, paths: [String])` — upserts `FileMeta` for
  each path and sets the flag (reuses the `meta(for:) ?? insert` pattern from
  `setMeta`), then saves once.
- `func hiddenPaths() -> Set<String>` — the set of paths with `hidden == true`,
  fetched via a `#Predicate { $0.hidden }`.

**View state:** `AppModel.showHidden: Bool` (persisted in UserDefaults under
`lume.showHidden`, same pattern as `filesOnly`).

**Filtering:** both regions filter their nodes against `hiddenPaths`:
- `showHidden == false`: hidden nodes are omitted entirely.
- `showHidden == true`: hidden nodes are shown **dimmed** (reduced opacity) with
  an inline **Un-hide** affordance (a small eye/eye-slash button on the row).

`FileTreeView.visibleChildren` gains the hidden filter alongside the existing
`filesOnly`/tag/`browseFilter` filters. The Favorites list filters its rows the
same way. A hidden flag is reactive via the existing `@Query private var
allMeta: [FileMeta]` in `SidebarView` (derive a `hiddenPaths` set from it, the
same way `names` is derived), so toggling updates immediately.

**Toggle UI:** add a **Show hidden** button toggle to the top bar next to
"Files only", styled the same (`.toggleStyle(.button)`, `controlSize(.small)`),
bound to `model.showHidden`.

### 6. Editing tags across a multi-selection

The existing single-row tags editor (`RowMetaView`) is unchanged for single
selection. For a **multi-selection**, "Edit Tags…" applies entered tags to every
selected path: a small sheet/popover takes a comma-separated tag string and
calls `store.setMeta(path:info:tagNames:displayName:)` per selected path,
preserving each path's existing `info`/`displayName` (read each via
`meta(for:)`). This is additive to the design; the single-row inline editor
remains the default for one row.

### 7. Open Folder — hold-⌃ path reveal

Replace the permanent `breadcrumb` header in the Open Folder section with a
**transient** ancestor path bar:

- The bar is shown only while **⌃ (Control)** is held. Tracked via an
  `AppModel.pathPeek: Bool` flag driven by key down/up.
- When shown, it renders `Breadcrumb.segments(for: browseRoot, home:)` (the
  existing, now crash-safe helper) as clickable chips above the folder's
  contents, current folder highlighted; the folder contents dim (reduced
  opacity) to signal the peek state.
- Clicking a chip calls `model.drillInto(segment.url)` and the bar collapses.
- Releasing ⌃ collapses the bar with no change.
- **⌃-click disambiguation:** because ⌃-click is the macOS secondary-click, the
  path-bar chips handle their click as navigation and suppress the row context
  menu *on the bar* (the bar only exists while ⌃ is down, so there is no
  ambiguity with normal rows).

**Key tracking:** an `NSEvent` local monitor for `.flagsChanged` (added on the
window/view via an `NSViewRepresentable` or `.onAppear`), setting
`model.pathPeek = event.modifierFlags.contains(.control)`. Cleared on disappear.
This is the standard way to observe a held modifier in AppKit/SwiftUI.

## Architecture & Files

**LumeCore (pure, unit-tested):**
- **Create** `Sources/LumeCore/PathExport.swift` — `PathExport.clipboardString(for:)`.
- **Create** `Tests/LumeCoreTests/PathExportTests.swift` — order preserved,
  newline joins, single path, empty input.
- **Modify** `Sources/LumeCore/Library/Models.swift` — add `FileMeta.hidden`.
- **Modify** `Sources/LumeCore/Library/LibraryStore.swift` — `setHidden(_:paths:)`,
  `hiddenPaths()`.
- **Modify** `Tests/LumeCoreTests/LibraryStoreTests.swift` — hide/un-hide round
  trip; `hiddenPaths()` set membership.

**LumeApp:**
- **Modify** `Sources/LumeApp/AppModel.swift` — `selectedRowIDs: Set<String>`,
  `selectedURLs`, `showHidden` (persisted), `pathPeek`, `copyPaths()`,
  `setHidden`/`unhide` wrappers, hidden-aware helpers.
- **Modify** `Sources/LumeApp/Sidebar/SidebarView.swift` — retitle sections
  (`FAVORITES`, `OPEN FOLDER · <name>`), `Set` selection binding, "Show hidden"
  toggle, derive `hiddenPaths` from `allMeta`, replace breadcrumb header with the
  ⌃-hold path bar, modifier-key monitor.
- **Modify** `Sources/LumeApp/Sidebar/FileTreeView.swift` — hidden filter in
  `visibleChildren`, dimmed + Un-hide affordance for hidden rows when
  `showHidden`, draggable rows (path/URL export).
- **Modify** `Sources/LumeApp/Sidebar/SidebarRow.swift` if needed for selection
  decoding helpers (already has `decode`).
- Context menu (`RowMenu`) + keyboard commands per §3.

## Testing

- **LumeCore:** `PathExport` and the `LibraryStore` hide/un-hide API are fully
  unit-tested (pure logic + SwiftData store, following existing test patterns).
- **App layer:** selection, copy-to-clipboard, hide/show filtering, the ⌃-hold
  path bar, and drag-out are verified by building and driving the app (this
  project has no view-layer unit tests). Confirm: multi-select + ⌥⌘C puts the
  expected newline-joined paths on the clipboard; Hide removes a row and Show
  hidden brings it back dimmed; Open promotes a favorite; holding ⌃ shows the
  path and clicking an ancestor re-roots.

## Out of Scope

- **LLM analysis of the copied paths** — the next milestone; it consumes the
  clipboard/path output this feature produces.
- A persisted, named "working set" data model — explicitly rejected; the
  multi-selection *is* the set.
- User-named custom favorite groups (drag-to-assign organizer) — considered and
  deferred; favorited folders already act as collections.
