# Scans — Design Spec

**Date:** 2026-06-08
**Status:** Approved (brainstorm), pending implementation plan

## Problem

The user keeps configuration/instruction files — `CLAUDE.md`, `memory.md`,
`aesthetics.md`, `.env`, `.json`, `.yaml` — scattered across many project
folders. The goal is to **improve these files via a chatbot/agent**, not to
hand-edit them in Lume. The actual loop is:

1. **Discover** every matching file across many locations (Lume today only
   opens one folder at a time — this is the biggest gap).
2. **Skim** the matches fast enough to decide which ones need an agent's
   attention.
3. **Grab the paths** of the chosen files and hand them to a chatbot ("improve
   these").

Editing happens in the chat, not in Lume. Lume is the **triage table** between
messy folders and the agent.

Export of paths already works (`Copy Paths`, ⌘⌥C). The missing pieces are
**Discover** and an efficient **skim/triage** view.

## Solution: Scans

A **Scan** is a saved recipe — *a set of filename patterns under a set of root
folders*. Example: patterns `CLAUDE.md, memory.md, aesthetics.md, .env` under
root `~/Developer`. The user creates it once, names it, and it persists in the
sidebar. Running it re-sweeps the disk and shows current reality.

A Scan is rule-based and dynamic. This is distinct from **Groups** (tag-based,
hand-picked, persistent membership). Scans and Groups do not interfere.

### 1. Sidebar: new "Scans" region

- A new sidebar region alongside the existing Open Folder / Favorites / Groups
  regions in `SidebarView.swift`.
- A "＋ New Scan" affordance opens a small sheet to define:
  - **Patterns:** comma-separated filenames or globs (e.g. `CLAUDE.md`,
    `memory.md`, `*.env`).
  - **Roots:** one or more folders (folder picker; multiple allowed).
  - **Name:** user-supplied label (e.g. "My CLAUDE rules").
- Each saved Scan renders as one clickable row in the region.
- Right-click a Scan row: Rename, Edit (patterns/roots), Delete.

### 2. Triage screen (list + live preview)

Clicking a Scan row runs the sweep and opens a two-pane triage view:

- **Left:** a compact checklist of every matched file, labeled by its
  parent-folder + filename (e.g. `lume/CLAUDE.md`) so identically-named files
  are distinguishable. Full path shown on the row or hover.
- **Right:** live preview of the focused file's contents, rendered with the
  existing per-type viewers via `DocumentRouter` (markdown highlight, env, etc.),
  read-only.
- **Keyboard:** ↑↓ moves focus and updates the preview instantly. **Space**
  toggles a "tick" on the focused file.
- **Tick set is sticky:** ticking is a persistent send-pile that survives as the
  cursor keeps moving (separate from the focus row). A running count is shown
  (`✓ 3 ticked`).

### 3. Handoff actions

Two buttons on the triage screen, acting on the ticked set:

- **Copy N paths** — newline-delimited POSIX paths, reusing the existing
  `PathExport.clipboardString(for:)` + clipboard write. Default action.
- **Copy as prompt** — same paths wrapped in a lead line, e.g.:

  ```
  Improve these files:
  /Users/manu/Developer/lume/CLAUDE.md
  /Users/manu/Developer/api/CLAUDE.md
  ```

  Ready to paste straight into a chatbot.

## Architecture fit (existing code to reuse)

| Concern | Reuse |
| --- | --- |
| Recursive file matching across roots | `FileService` / `FileSystemCache` (`Sources/LumeKit/FileSystem/`) |
| Type-aware preview | `DocumentRouter` + `Viewers/*` |
| Path → clipboard | `PathExport` (`Sources/LumeKit/Document/`) |
| Sidebar regions + rows | `SidebarView.swift` |
| Central state | `AppState.swift` (add Scans state: saved scans, active scan results, ticked set, focus) |
| Persistence of saved scans | SwiftData `Library` models (`Sources/LumeKit/Library/Models.swift`) — add a `Scan` model: name, patterns, roots |

A `Scan` SwiftData model stores `name`, `patterns: [String]`, `roots: [URL/bookmark]`.
Sweep results are transient (recomputed on run); only the recipe is persisted.

### Pattern matching

- Patterns are matched against **filename only** (not full path).
- A literal like `CLAUDE.md` matches exact filename; globs like `*.env` match by
  suffix/glob. Case-insensitive match is acceptable for v1.
- Roots are stored as security-scoped bookmarks so saved scans survive relaunch
  (sandbox-safe, consistent with existing folder-access handling).

### Scope of the sweep

- Recursive descent from each root.
- Respect Lume's existing hidden-file conventions; but **`.env` and other
  dotfiles must still be discoverable** even though they are "hidden" — pattern
  match overrides the hidden filter for explicitly-named patterns.
- Reasonable guardrails: skip `node_modules`, `.git`, and similar heavy dirs by
  default (v1 hardcoded ignore list; configurable later).

## Out of scope (YAGNI)

- ❌ In-app editing of matched files (the agent edits them).
- ❌ Card-grid / contact-sheet view (list + preview was chosen).
- ❌ Bundling file *contents* into the clipboard — paths only.
- ❌ Bulk find/replace across files.
- ❌ Auto-refresh/file-watching of scan results (manual re-run on click is fine
  for v1).

## Success criteria

1. User can create, name, and save a Scan with multiple patterns and roots.
2. Clicking a saved Scan lists every matching file across all roots, including
   dotfiles like `.env`.
3. Arrow keys skim the list with instant type-correct previews on the right.
4. Space ticks/unticks files into a sticky send-pile with a visible count.
5. "Copy N paths" and "Copy as prompt" place the ticked files' paths on the
   clipboard in the documented formats.
6. Saved Scans persist across app relaunch and re-run correctly.
