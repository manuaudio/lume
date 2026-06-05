# Design: GROUPS — a tag-driven navigator

**Date:** 2026-06-05
**Status:** Approved (brainstorm complete) — ready for implementation planning
**Branch target:** `main` (current working branch)

## Summary

Add a **GROUPS** region to the sidebar: a flat list of the user's tags, each
rendered as an **expandable folder** whose contents are *every file carrying
that tag, from anywhere on disk*. A file with multiple tags appears under
multiple groups. This is a navigation/organization layer on top of the real
filesystem, driven entirely by the existing `Tag ⇄ FileMeta` many-to-many model.

The motivating workflow: gather files that live in different real locations
(agent prompts, configs, notes) into project-named groups, then read them, edit
them, and grab their paths quickly to hand to AI agents.

## Goals

- Organize scattered real files into virtual "project" folders without moving
  them on disk.
- One gesture to add a file to a group: **tag it**.
- Fast access to a group's file paths (Copy Paths) for handing to agents.
- Keep the curated FAVORITES region and the real-folder browser as-is, separate.

## Non-goals (explicitly out of scope for v1)

- **Nested groups / sub-tags.** Tags stay flat. (Considered and declined — may
  revisit later via path-style names or a `Tag.parent` relationship; the GROUPS
  UI would stay identical, only storage would change.)
- Manual ordering of files within a group (v1 is alphabetical).
- Smart/rule-based groups (saved searches). Groups are exactly tags.

## Decisions (from brainstorming)

1. **Membership model:** tags act as folders; a file can live in many groups at
   once (many-to-many) — matches the existing tag model.
2. **Population:** a group shows *all* files with that tag, wherever they live on
   disk (not just pinned files). Tagging a file *is* adding it to the group.
3. **Nesting:** none. Flat list of groups.
4. **Regions are separate:** GROUPS, FAVORITES, and OPEN FOLDER (browser) are
   three distinct sidebar sections.
5. **Tag-filter is replaced:** the old "click a tag chip to filter the open
   folder" behavior is removed; expanding a group supersedes it (and shows files
   from everywhere, not just the open folder).
6. **Empty groups persist.** A user-created group with zero files is valid and
   is NOT auto-pruned. → **Remove the current orphan-tag auto-prune.** A group is
   deleted only when the user explicitly deletes it.

## Sidebar structure

Three stacked regions (top to bottom):

1. **GROUPS** (new) — flat list of tags as expandable, color-tinted folders.
   - Header row per tag: 🏷 color-tinted icon · tag name · file count.
   - Expanded: each tagged file as a row showing display name + muted real path.
   - A **＋ New Group** affordance creates a named, empty, persistent tag.
2. **FAVORITES** (existing) — pinned real files/folders. Unchanged except the
   click-behavior change below.
3. **OPEN FOLDER** (existing) — the real filesystem browser. Unchanged.

## Interaction model (all regions, unless noted)

- **Single-click** a row → select it. A file selection shows its content in the
  document pane (existing behavior).
- **⌘-click / ⇧-click** → multi-select (toggle / contiguous range).
- **Double-click a real folder** (FAVORITES or browser) → open it in the OPEN
  FOLDER browser below (`drillInto`). **Pinned folders no longer auto-expand
  inline on single-click** — this replaces the current Wave-4 behavior where a
  single click on a pinned folder toggled inline expansion.
- **Double-click a group** (virtual tag-folder) → expand/collapse (no disk
  folder to open).
- **Drag a file onto a group** → tags it with that group (adds to the group).
  **Drag a file onto FAVORITES** → pins it (existing drag-to-pin).
- **Select a group, or select files, → Copy Paths** → newline-separated absolute
  paths to the clipboard. For a selected group, copies all of its files' paths.

### Context menus

- **Group row:** Rename, Recolor, Copy Paths (all files), Delete Group.
- **File row under a group:** Open, Copy Path, **Remove from "{group}"** (untags
  only that one tag — the file stays in its other groups and on disk),
  Reveal in Finder.

## Defaults

- **File order within a group:** alphabetical by effective display name. The real
  path is shown muted as a secondary string (disambiguates same-named files).
- **New Group:** prompts for a name, creates an empty `Tag`, and makes it the
  current drag/tag target. Persists even while empty.

## Data model

Reuses the existing models unchanged:

- `Tag { name (unique), colorIndex, files: [FileMeta] }`
- `FileMeta { path (unique), info, displayName, hidden, tags: [Tag] }`

No schema migration required. The only model-adjacent behavior change is in
`LibraryStore`: **stop auto-pruning orphaned tags** (so empty groups persist).
Audit every current `pruneOrphanTags()` call site (e.g. inside `setMeta`,
tag removal) and remove/disable the prune.

## What changes in code (implementation outline, not binding)

- **New `GroupsSection` (or extend `SidebarView`)**: render tags as expandable
  folders. Source files per tag from `LibraryStore` (all `FileMeta` with the
  tag), sorted alphabetically. Reuse `TagPalette` colors.
- **Group rows** participate in selection (`selectedRowIDs`) using a row-id
  scheme that distinguishes a group header, a file-under-a-group (the same real
  file can appear under several groups, so the id must encode the owning group +
  path), a favorite, and a browser row. Extend `SidebarRow` / the id grammar
  accordingly, and keep `RowSelection` math working.
- **Remove the TAGS filter section** and the tag-filter state/path on `AppModel`
  (`activeTagFilters`, `tagFilteredPaths`, match-all toggle, the filter bar). Make
  sure the browser no longer filters by tag.
- **Pinned-folder click change**: in `clickRow` / the sidebar row gestures, a
  single click on a pinned (or any real) folder selects only; double-click drills
  into the browser. Groups expand on double-click.
- **Drag-to-tag**: add a `.dropDestination(for: URL.self)` per group that calls a
  new `model.tag(_ urls:withTagNamed:)`.
- **Group-scoped Copy Paths**: a method returning all paths for a tag, joined by
  newlines, to the pasteboard.
- **New Group / Rename / Recolor / Delete / Remove-from-group**: wire to existing
  `LibraryStore` tag operations (`recolorTag`, `renameTag`, `deleteTag`, `setMeta`)
  plus a new "create empty tag" and "remove single tag from file" path.
- **Remove orphan auto-prune** in `LibraryStore`.
- **Keep** the existing document tag header / inline tag editor — they remain the
  other way to add tags, and now also populate GROUPS.

## Testing

- Pure selection math (`RowSelection`) updated for the new id grammar — extend
  `RowSelectionTests`.
- `LibraryStore`: a group lists all tagged files regardless of location; empty
  groups persist (no prune); remove-single-tag leaves other tags intact;
  group-paths Copy returns newline-joined absolute paths. Extend store tests.
- `FileOps`-style pure helpers for any new naming/sorting logic, with tests.
- GUI interactions (single/double-click, drag-to-tag, expand) verified manually
  by the user (no headless GUI test harness).

## Open follow-ups (future, not v1)

- Nested groups (sub-tags) — storage choice deferred.
- Manual file ordering within a group.
- Dragging a file *out* of a group to remove the tag (context menu covers it for v1).
