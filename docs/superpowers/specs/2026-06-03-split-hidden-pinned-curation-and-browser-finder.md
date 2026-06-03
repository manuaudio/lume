# Split Hidden: Pinned Curation vs Browser Finder-Hidden — Design

**Date:** 2026-06-03
**Status:** Approved (verbal), ready for implementation plan
**Predecessor:** the single `showHidden` toggle (commit 6b15c67) that both omitted
user-hidden items and revealed Finder dotfiles, in both regions.

## Goal

Split the one "Show hidden" control into two independent, region-scoped systems:

1. **Pinned curation** — hide individual files *and* subfolders from inside a
   pinned folder so the FAVORITES list shows only the handful you care about,
   with a toggle to reveal them again and add them back.
2. **Browser Finder-hidden** — a separate toggle in the OPEN FOLDER region that
   reveals normal Finder-hidden files (dotfiles like `.env`, `.claude`).

The two are unrelated: curation shapes *your* Favorites view; the browser toggle
shows *reality* including OS-hidden files. Each region owns its own control.

## Approved Decisions (from brainstorming)

1. **Hide scope = Pinned only.** Hiding a file/folder removes it from the
   FAVORITES region only. The same path stays fully visible in OPEN FOLDER when
   you browse its real folder. The browser is a complete view of reality.
2. **Two controls, one per region** (not in the top bar). An eye toggle in the
   FAVORITES header (reveals Favorites-hidden items) and a separate eye toggle in
   the OPEN FOLDER header (reveals Finder dotfiles).
3. **Hidable in pinned = files and folders.** Hiding a subfolder hides its whole
   subtree from Favorites. Multi-select + right-click → Hide.
4. **The meaning of `FileMeta.hidden` narrows** to "hidden from Favorites." No
   schema change. Anything already hidden becomes Favorites-hidden and reappears
   in the browser — the intended new model.
5. **`Files only` is unchanged** (stays a global top-bar toggle).

## Design

### 1. Data model (no schema change)

`FileMeta.hidden: Bool` is reused; its meaning narrows from "hidden everywhere"
to **"hidden from the FAVORITES region."** The OPEN FOLDER region ignores it.

`LibraryStore.setHidden(_:paths:)` and `hiddenPaths()` are unchanged in
signature and behavior (they still read/write `FileMeta.hidden`); only the
display semantics in the views change.

### 2. App state (`AppModel`)

Replace the single `showHidden` with two persisted flags (same UserDefaults
pattern as `filesOnly`):

- `var showPinnedHidden = false` — UserDefaults `lume.showPinnedHidden`. Reveals
  Favorites-hidden items in the FAVORITES region (dimmed + un-hide affordance).
- `var showBrowserHidden = false` — UserDefaults `lume.showBrowserHidden`.
  Reveals Finder dotfiles in the OPEN FOLDER region.

The old `lume.showHidden` key is abandoned (defaults to the new flags' `false`).
All existing references to `model.showHidden` are replaced by the
region-appropriate flag.

New command wrappers stay as they are; `setHiddenForSelection`, `unhide`,
`selectionIsAllHidden` continue to operate on `FileMeta.hidden`.

### 3. Toggles in section headers

Remove the top-bar **Show hidden** toggle. Keep **Files only** in the top bar.

Each section header becomes an HStack with a trailing borderless eye button
(`controlSize(.small)`), styled consistently:

- **FAVORITES** header → eye bound to `showPinnedHidden`.
  `eye`/`eye.slash` icon, help: "Show items hidden from Favorites".
- **OPEN FOLDER · \<name\>** header → eye bound to `showBrowserHidden`.
  `eye`/`eye.slash` icon, help: "Show hidden files (.env, .claude…)".

Headers use a shared small helper view (e.g. `SectionHeader(title:isOn:help:)`)
so both look identical.

### 4. Region behavior

`FileTreeView` already carries its `section` (`.pinned` / `.browser`). Behavior
forks on it:

**FAVORITES (`.pinned`):**
- A pinned folder expands to show **all** its contents — files and folders
  (the curation surface). It always enumerates with `includeHidden: false`
  (Finder dotfiles stay hidden here, except `.env*` as today); revealing
  dotfiles is the browser's job.
- `visibleChildren` filters out paths in `hiddenPaths` **unless**
  `model.showPinnedHidden` is on.
- When `showPinnedHidden` is on, hidden rows render dimmed (opacity ~0.45) with
  an inline **un-hide** eye affordance (existing pattern).
- Reactivity: `hiddenPaths` is derived from the existing `@Query allMeta`, and
  `showPinnedHidden` is `@Observable`, so toggling/hiding updates immediately —
  no re-enumeration needed for the pinned filter.

**OPEN FOLDER (`.browser`):**
- Never filters on `FileMeta.hidden` (no curation here).
- Enumerates with `includeHidden: model.showBrowserHidden`; re-enumerates via
  `.onChange(of: model.showBrowserHidden)` when the toggle flips.
- No dim / un-hide affordance.

`FileTreeView.reload()` and the `State(initialValue:)` seed compute
`includeHidden = (section == .browser) ? model.showBrowserHidden : false`.
The `.onChange(of: model.showHidden)` watcher is replaced by
`.onChange(of: model.showBrowserHidden)` (only relevant for browser; harmless
for pinned, but gate the reload to `.browser` or simply reload — reloading the
pinned tree on that flag is a no-op for contents).

Top-level FAVORITES rows (`pinnedSection`'s `ForEach` over `visibleFavorites`)
keep filtering on `hiddenPaths` gated by `showPinnedHidden`, for consistency.

### 5. Context menu (`RowMenu`)

`RowMenu` already receives `section`. Adjust items:

- **Hide / Un-hide** (⌘⌫): shown **only when `section == .pinned` and the row is
  a nested item** (i.e. `!model.isPinned(url)` — not a top-level favorite).
  Operates on the selection (`setHiddenForSelection`), label reflects state
  (`selectionIsAllHidden`). Removed entirely from the browser menu.
- **Unpin**: shown for top-level favorites (`section == .pinned &&
  model.isPinned(url)`), as today.
- **Pin**: shown in the browser (`section == .browser`) as today (the way items
  enter Favorites).
- **Open / Copy Path(s) / Edit Tags… / Rename… / Reveal in Finder**: unchanged,
  both regions.

Rationale: a nested item inside a pinned folder isn't itself a `Favorite`
record, so `Unpin` doesn't apply — `Hide` curates it. A top-level favorite is
removed with `Unpin`. The two never both apply to the same row.

## Architecture & Files

**LumeApp only (no LumeCore changes — `enumerate(includeHidden:)` already exists):**
- **Modify** `Sources/LumeApp/AppModel.swift` — replace `showHidden` with
  `showPinnedHidden` + `showBrowserHidden` (both persisted); update `init`.
- **Modify** `Sources/LumeApp/Sidebar/SidebarView.swift` — remove the top-bar
  Show-hidden toggle; add eye toggles to the FAVORITES and OPEN FOLDER section
  headers (shared `SectionHeader` helper); `pinnedSection` filter uses
  `showPinnedHidden`.
- **Modify** `Sources/LumeApp/Sidebar/FileTreeView.swift` — `visibleChildren`
  filters `hiddenPaths` only for `.pinned` (gated by `showPinnedHidden`);
  `reload()`/seed compute `includeHidden` from `section` + `showBrowserHidden`;
  `.onChange` watches `showBrowserHidden`; dim/un-hide affordance only for
  `.pinned`; `RowMenu` Hide/Un-hide gated to nested pinned rows.

## Testing

- **LumeCore:** unchanged; `enumerate(includeHidden:)` already covered.
- **App layer (build + drive the app):** confirm —
  (a) expanding a pinned folder shows files **and** subfolders;
  (b) selecting nested items + Hide removes them from FAVORITES while they remain
      visible in OPEN FOLDER for the same folder;
  (c) the FAVORITES eye reveals hidden items dimmed with un-hide; un-hiding
      restores them;
  (d) the OPEN FOLDER eye reveals/hides Finder dotfiles independently of the
      FAVORITES eye;
  (e) Hide is absent from the browser context menu; Unpin only on top-level
      favorites; Hide only on nested pinned rows.

## Out of Scope

- Revealing Finder dotfiles inside pinned folders (pinned keeps the default
  `.env`-only behavior; a follow-up if needed).
- Any change to `Files only`, tags, Copy Paths, or the hold-⌃ path peek.
- A separate "show only allowlist" model — curation is a denylist (Hide), as
  decided.
