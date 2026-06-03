# Display Names v2 — Design

**Date:** 2026-06-03
**Status:** Approved (verbal), ready for implementation plan
**Predecessor:** the original `FileMeta.displayName` feature (label shown instead of filename)

## Goal

Make the sidebar's "display name" smarter so duplicate-named files (many `.env`,
many `CLAUDE.md`) are distinguishable at a glance, while the real filename stays
visible as a reference. The current behavior replaced the filename with a single
label and only ever came from a manual edit; this design adds automatic
parent-folder naming for a known set of ambiguous files and always shows the
real filename muted alongside the label.

## Approved Decisions (from brainstorming)

1. **Auto-name trigger = curated built-in list** of recurring filenames.
2. **Scope:** auto parent-folder naming applies **only in the Pinned list**;
   user-set names apply **everywhere** (Pinned + Browser); the muted real
   filename shows wherever a display label differs from the filename.
3. **Clearing a name reverts to the auto-default** (Pinned) or plain filename.
4. **Layout:** real filename trailing **after** the name (same line), muted.

## Approach

**Compute auto-names; store only overrides.** The parent-folder name is derived
at render time and never written to SwiftData. `FileMeta.displayName` continues
to store *only* a user override. This keeps clearing reversible and lets the
ambiguous-file list evolve without data migration.

## Design

### 1. Auto-name rule (pure logic, LumeCore, unit-tested)

New `DisplayName.autoName(for url: URL) -> String?`:
- Returns the **parent folder name** (`url.deletingLastPathComponent().lastPathComponent`)
  when the file's basename matches the curated ambiguous set, else `nil`.
- Case-insensitive matching.

Curated ambiguous set (basename, with one glob):
`.env`, `.env.*` (e.g. `.env.local`, `.env.production`), `CLAUDE.md`,
`AGENTS.md`, `GEMINI.md`, `README.md`, `index.html`, `index.md`,
`package.json`, `Dockerfile`, `docker-compose.yml`, `Makefile`, `.gitignore`.

Matching rule: exact case-insensitive basename match, plus the `.env.*` prefix
rule (basename equals `.env` or starts with `.env.`).

### 2. Effective label per context

- **Pinned row:** `userOverride ?? autoName(url) ?? filename`
- **Browser row:** `userOverride ?? filename` (no auto-name — the folder is
  already visible in the tree)
- The **muted filename reference** renders whenever the effective label ≠ the
  real filename. Folders are unchanged (no reference, no auto-name).

`userOverride` = `FileMeta.displayName` when non-empty (today's `names[path]`).

### 3. Visual treatment

A file row renders: `[kind icon]  EffectiveName   filename`
- `EffectiveName`: primary color, normal weight, `.lineLimit(1)` middle-truncated.
- `filename`: trailing, `.secondary`/muted color, slightly smaller
  (e.g. `.caption`), truncates first when space is tight.
- Shown only when `effectiveName != filename`; otherwise just the filename as
  today.

### 4. Editing semantics (extends `RenameField`)

- **Pre-fill** the rename field with the current **effective** label (so editing
  a pinned `.env` starts from "freshydeli", not blank or ".env").
- **On commit**, compute what to store:
  - If trimmed text == filename **or** == `autoName(url)` → store `""`
    (no override; stays auto/plain).
  - Else → store the trimmed text as the override.
- This lets the user type a custom name, accept the auto-name (stores nothing),
  or clear back to the auto-default.

Note: `autoName` here is the Pinned-context auto-name. In the Browser the
effective default is the filename; the same commit rule still holds because
`autoName(url)` is `nil` only for non-ambiguous files, where the filename branch
applies.

## Architecture & Files

- **Create** `Sources/LumeCore/DisplayName.swift` — pure `DisplayName.autoName(for:)`
  + the ambiguous-set predicate. One responsibility, no SwiftUI/SwiftData deps.
- **Create** `Tests/LumeCoreTests/DisplayNameTests.swift` — each ambiguous
  pattern (incl. `.env.local`, case-insensitivity), non-matches (e.g. `notes.md`,
  `main.swift`), parent extraction, and a path at filesystem root.
- **Modify** `Sources/LumeApp/Sidebar/FileTreeView.swift`:
  - `FileRow`/`SidebarItemRow` render effective name + muted filename. Pass an
    `autoName` (or a flag) so Pinned rows can apply it and Browser rows don't.
  - `RenameField` pre-fill + clear logic updated per §4.
- **Modify** `Sources/LumeApp/Sidebar/SidebarView.swift`:
  - Pinned section computes `DisplayName.autoName(for:)` per row and passes it in.
  - Browser section passes no auto-name.

No new persisted fields; no SwiftData migration.

## Testing

- LumeCore: `DisplayName.autoName` is fully unit-tested (pure function).
- App layer: rendering and rename pre-fill/clear are verified by building and
  driving the app (this project has no view-layer unit tests). Confirm: a pinned
  `.env` shows its parent folder + muted `.env`; a browser `.env` shows plain
  `.env`; renaming a pinned `.env` to a custom string persists; clearing reverts
  to the parent-folder auto-name.

## Out of Scope

- Renaming the actual file on disk (this is display-only, by design).
- Dynamic collision detection (auto-name only on real duplicates) — considered
  and rejected in favor of the predictable curated list.
- Making the ambiguous list user-configurable (could be a later enhancement).
