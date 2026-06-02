# Lume Sidebar UX Redesign — Design

**Date:** 2026-06-02
**Status:** Approved, ready for planning

## Goal

Turn Lume into a pro-feeling, two-pane workspace. Collapse the three-pane
layout into **Sidebar + Document**, fold the Info panel's editing powers
directly into the sidebar, and replace the Favorites/Browse mode toggle with a
single powerful, navigable, customizable tree. Add real keyboard control and
right-click menus. Separately, stop mislabeling Claude Cowork artifacts as
"broken HTML."

## Why

Today the user must cross from the left sidebar to the right Info panel to
rename a file, folders only expand via a tiny disclosure triangle, tags are
dead labels, there are almost no keyboard commands, and the sidebar is split
into two mutually exclusive modes. The result feels under-powered. This redesign
consolidates everything into one place with consistent, discoverable
interactions.

## Non-Goals

- Implementing a `window.cowork.callMcpTool` bridge or any live Google Drive /
  MCP data fetching for HTML artifacts. Out of scope — arguably not Lume's job.
- A general HTML renderer rewrite. `WKWebView` already renders self-contained
  HTML/CSS/JS correctly; no known self-contained file renders wrong.
- Multi-window / tabs. Single window stays.

## Current Architecture (baseline)

- `ContentView` hosts a 3-column `NavigationSplitView`:
  `SidebarView | (DocumentSurfaceView + InfoPanelView)`.
- `SidebarView` uses a segmented `Picker` bound to `AppModel.sidebarMode`
  (`.favorites` / `.browse`) and swaps its whole content between the two.
- Folder rows are `DisclosureGroup`s (`DirectoryRow`, `FavoriteFolderRow`) —
  only the triangle toggles expansion; the label is inert.
- `InfoPanelView` (right pane) is the only place to edit `displayName`, `tags`,
  and `notes`, behind a manual Save button.
- Selection is `AppModel.selectedFile` with custom row highlighting (no native
  `List(selection:)`).
- SwiftData models: `Favorite`, `Bookmark`, `Tag`, `FileMeta` (in LumeCore),
  persisted to an explicit on-disk store. `Favorite` carries `kindRaw`
  ("folder" sentinel for dirs) and a `sortIndex`; `Bookmark` carries a
  `sortIndex`. `FileMeta` holds `displayName`, `info` (notes), and `tags`.
- Commands: only `⌘O` (open folder). Right-click menu only toggles
  favorite / bookmark.

## Target Design

### 1. Two-pane layout

`NavigationSplitView` becomes `Sidebar | Document`. `InfoPanelView` is removed
as a column. The toolbar's "Info" toggle button is removed. `AppModel`
`showInfoPanel` is removed.

### 2. One unified sidebar (no mode toggle)

Remove the Favorites/Browse `Picker` and `AppModel.sidebarMode` /
`SidebarMode`. The sidebar is a single vertical stack, top to bottom:

**① Pinned** — favorites and "pin to browse" merge into ONE pin concept. You can
pin **files or folders** to the top. Drag to reorder (existing `sortIndex`
machinery on `Favorite`). The `Bookmark` model and "Pin to Browse" action are
retired; on first launch, existing bookmarks are migrated into pinned
favorites (folders). Default seeded pins on a fresh store: Home, Documents,
Desktop, iCloud Drive (same candidates `seedDefaultBookmarksIfNeeded` uses
today).

**② Tags** — a collapsible chip row. Clicking a tag sets an active filter
(`AppModel.activeTagFilter`, already present) that filters the Browser below to
files whose `FileMeta.tags` contain it. Clicking the active tag again clears the
filter. Tag chips come from the existing `Tag` `@Query`.

**③ Browser** — the main navigation area for a current location:
- A **breadcrumb / path bar** at its top shows the current location, with an
  **up (`cd ..`) button**. New `AppModel.browseRoot: URL` drives this; the
  breadcrumb renders ancestors as clickable segments.
- **Single-click a folder → expand/collapse inline** (disclosure). Fixes the
  "tiny triangle only" gripe — the whole row toggles.
- **Double-click a folder → drill in**: sets `browseRoot` to that folder; the
  breadcrumb updates. `⌘↑` and the up button do `cd ..`.
- **Single-click a file → open it** in the document pane (`selectedFile`).
- **Files-only toggle** in the sidebar header (`AppModel.filesOnly: Bool`,
  persisted) hides folder rows so the user can scan files only.

### 3. Inline metadata editing (replaces the Info panel)

When a row is selected:
- **Rename** via `⏎`, `⌘R`, or right-click → "Rename…". Opens an in-place
  `TextField` on the row; commits on Enter, cancels on Esc; writes
  `FileMeta.displayName` (same field the Info panel wrote). Double-click is NOT
  used for rename (it is drill-in for folders).
- **Tags** render as small chips beneath the selected row; a `+` affordance adds
  a tag inline (writes `FileMeta.tags`).
- **Notes** live in a slim expandable area on the selected row (click a
  disclosure to reveal a small text editor). **Autosaves** on edit (debounced) —
  no Save button.

All three reuse `LibraryStore.setMeta(path:info:tagNames:displayName:)`.

### 4. Right-click context menu (everywhere)

A single menu shared by files and folders, items enabled by kind:
Open · Drill In (folders) · Pin / Unpin · Rename… · Edit Tags… · Reveal in
Finder. Replaces the current favorite/bookmark-only `FavoriteMenu`.

### 5. Keyboard commands

| Key | Action |
| --- | --- |
| `↑` / `↓` | Move selection |
| `→` / `←` | Expand / collapse folder |
| `⌘↑` | Drill up (`cd ..`) |
| `⏎` | Open file / drill into folder |
| `Space` | Quick Look selected file |
| `⌘R` | Rename selected row |
| `⌘D` | Pin / unpin selected row |
| `/` | Focus the filter field |
| `⌘O` | Open folder (existing) |

Selection-driven keys require a keyboard-focusable, selection-backed list. The
sidebar moves to a native `List(selection:)` over a flat, identifiable row model
(see Architecture Notes) so arrow keys and these shortcuts work; custom
highlighting is reconciled with native selection.

### 6. HTML: detect-and-label Cowork artifacts

`HTMLViewer` (or a small wrapper) inspects the file before loading. If it
contains a `<script ... id="cowork-artifact-meta">` marker (and/or references
`window.cowork`), Lume shows a clean native banner above the web view:
*"Claude artifact — needs live connectors (won't load data outside Claude)."*
The HTML still renders beneath it. Self-contained HTML is unaffected and renders
as today. No renderer changes.

## Architecture Notes

- **Row model.** Introduce a lightweight, `Identifiable`/`Hashable` row type
  (e.g. `SidebarRow` keyed by path + a kind/section discriminator) so the
  sidebar can use native `List(selection:)` and keyboard navigation while still
  rendering the three sections. Expansion state and the inline-edit state
  (which row is being renamed / has notes open) live in view state keyed by
  path, replacing today's per-row `@State` disclosure flags where it conflicts
  with reuse.
- **AppModel changes:** remove `sidebarMode`, `showInfoPanel`; add `browseRoot`,
  `filesOnly`; keep `activeTagFilter` (now wired). Add a unified `pin(_:)` /
  `unpin(_:)` over `Favorite` and a `drillInto(_:)` / `drillUp()`.
- **Model migration:** retire `Bookmark`. On launch, if bookmarks exist, convert
  each to a folder `Favorite` (pinned), then ignore the `Bookmark` table. Keep
  the `Bookmark` type defined to avoid a destructive SwiftData schema break, but
  stop reading/writing it. (Planner to confirm the least-risky migration path.)
- **Files to touch:** `ContentView` (drop 3rd column + Info toggle),
  `SidebarView` (full rewrite to unified tree), `FileTreeView` (row
  interactions, inline edit, context menu), `AppModel` (state + actions),
  `LumeApp` (commands), `HTMLViewer` (artifact detection). `InfoPanelView` is
  deleted.
- `SidebarView`/`FileTreeView` are growing past one responsibility; split the
  inline-edit row, the browser/breadcrumb, the pinned section, and the tags
  section into focused subviews.

## Testing

- LumeCore store logic (pin/unpin unification, bookmark→favorite migration, tag
  filtering predicate) gets unit tests via the existing Swift Testing setup
  (`@MainActor` SwiftData tests are known-good — see prior session).
- App-layer interactions (single vs double click, keyboard map, inline rename
  commit/cancel, files-only toggle, artifact banner) are verified by building
  and driving the app (launch helper + screenshots), since SwiftUI view
  interactions aren't unit-tested in this project.

## Open Questions for Planning

- Exact, least-destructive SwiftData migration for retiring `Bookmark`.
- Whether the breadcrumb drill model and inline tree-expansion can share one
  scroll region cleanly, or whether drill-in should swap the browser's root list
  entirely.
