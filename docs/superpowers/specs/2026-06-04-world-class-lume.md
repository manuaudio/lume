# World-Class Lume — Engineering Spec & Roadmap

**Date:** 2026-06-04
**Status:** Active. Living document — append world-class requirements here.
**Goal:** Make Lume a fast, lean, world-class macOS app: modern Swift, modular frameworks, native/GPU-accelerated rendering, and the full breadth of Apple platform technologies. No bloat, no jank.

> Driving feedback: the left panel is *very* slow; native apps we build feel bloated and slow; extract reusable/"scriptable" code into real frameworks; everything should feel like a first-class OS X app and use hardware acceleration.

---

## Guiding Principles
- **Fast by construction.** No work on the main thread that can be cached or moved off it. No invalidation storms — a change updates only what it affects.
- **Lean.** Delete heavy/duplicated code. Prefer native frameworks over dependencies. Every dependency must earn its place.
- **Modern Swift.** Swift 6 strict concurrency, `@Observable`, structured concurrency (`async/await`, actors), `Sendable`. No deprecated APIs (audit against the SwiftUI skill's `latest-apis.md`).
- **Modular.** App-agnostic logic lives in focused frameworks under `Frameworks/`; `LumeApp` is thin SwiftUI wiring.
- **Native & accelerated.** Layer-backed (Core Animation), GPU-composited views; Metal/Core Image where it pays; Quick Look, PDFKit, etc. used correctly.

---

## Phase 0 — Crash & correctness fixes (DONE)
- [x] **JPEG crash.** `QLPreviewView.setPreviewItem` aborted (`_QLRaiseAssert`) when assigned before the view was in a window (local images ran the iCloud completion synchronously in `makeNSView`). Fix: native layer-backed `ImageViewer` (off-main decode, zoom/pan, GPU-composited) for images; `QuickLookViewer` (office/long-tail only) defers `previewItem` until in-window via structured concurrency. (commit e223dc6)

## Phase 1 — Performance: kill the sidebar invalidation storm (DONE)
Root cause (audited): `SidebarView` holds `@Query allMeta:[FileMeta]` (every metadata row) and rebuilds `names`/`hiddenPaths` collections on every body eval, threaded **by value** into every row → one tag/notes/hide edit re-renders the whole tree; each re-render reconstructs `FileTreeView`s which re-read the disk via the **uncached** `FileService.enumerate`. (commits f6eb57d, de7fff8)
- [x] **Directory-enumeration cache + watcher:** `FileSystemCache` (per-`(path,includeHidden)` memoization + revision ticker) and `DirectoryWatcher` (FSEvents, no polling) eliminate per-render disk I/O and auto-refresh on external changes. (Extracted into `FileSystemKit` in Phase 2.)
- [x] **Stop the storm:** `MetaIndexLoader` isolates the all-metadata `@Query` in a leaf view; rows receive scalar `displayName: String?` / `isHidden: Bool` (not freshly-built collections) so only the affected row invalidates.
- [x] Verify: build clean, 4 new `FileSystemCache` tests, 112/112 pass. *(Pending: user click-verification + Instruments launch trace.)*

## Phase 2 — Maximal modularization (`Frameworks/`) (DONE)
Split the `LumeCore` grab-bag into focused, app-agnostic frameworks; thin `LumeApp`. (commits 55eaf60, 64b3d43)
- [x] `FileSystemKit` (base) — `FileKind`, `FileNode`, `FileService`, `FileSystemCache`, `DirectoryWatcher`.
- [x] `LibraryKit` → FileSystemKit — SwiftData models (Tag/FileMeta/Favorite/Bookmark), `LibraryStore`, `TagSuggest`, `TagPalette`.
- [x] `DocumentKit` → FileSystemKit — `DocumentRouter`, `DisplayName`, `Breadcrumb`, `PathExport`.
- [x] `ConfigKit` (leaf) — `EnvFile`. (pluggable `ConfigFormat` registry lands in Phase 3.)
- [x] `SelectionKit` (leaf) — `RowSelection`.
- [x] `LumeUI` → LibraryKit — reusable SwiftUI components (`TagChip`, `TagSwatchPicker`, `TagField`, `FlowLayout`).
- [x] `LumeApp` — executable: AppModel, scenes, wiring.

> **Decision — `FileKind` placement.** The original sketch put `FileKind` in `DocumentKit`, but it is used by `FileNode` (filesystem), `DocumentRouter` (document), and `LibraryStore` (library). Placing it in `DocumentKit` would force FileSystemKit and LibraryKit to depend *up* on the document layer. It now lives in the base `FileSystemKit`, keeping the dependency graph acyclic (FileSystemKit ← {LibraryKit, DocumentKit}; LibraryKit ← LumeUI; everything ← LumeApp).
>
> **Decision — umbrella facade.** `LumeCore` is retained as a thin target that `@_exported import`s the five logic kits, so existing `import LumeCore` sites in `LumeApp` are untouched while the inter-kit boundaries are compiler-enforced. Flipping app imports to direct kit imports and dropping the umbrella is a safe future cleanup. (`LumeUI` is *not* in the umbrella — UI views import it directly.)
>
> **`SidebarRow` id math** stays in `LumeApp/Sidebar` for now (couples to view identity); migrate to `SelectionKit` if it proves reusable. `EnvView` stays in `LumeApp` (couples to `AppModel`).

## Phase 3 — Structured "vibecoder-friendly" config viewers
Editable structured views like the `.env` editor, **toggleable** (structured ⇄ raw source), with an **extensible registry** so any applicable format gets one.
- [ ] `ConfigFormat` protocol + registry: parse → editable tree/key-value model → serialize. Pluggable so new formats drop in.
- [ ] Formats: **JSON** + **plist** (Foundation, safe round-trip), **YAML**, **TOML** (vetted lightweight deps; be honest about comment-preservation limits). Extend to `.xml`, `.ini`, `.csv`, etc. where a structured view helps.
- [ ] Per-file (and global default) toggle between the structured editor and raw text. Persisted.
- [ ] Save-back through the same coordinated/iCloud-aware write path; preserve formatting where feasible.

## Phase 4 — Modernization & "world-class OS X" sweep
Cross-cutting; apply throughout. Audit against `latest-apis.md`.
- **Concurrency:** Swift 6 strict concurrency clean; `async/await` for all I/O; actors for shared mutable state; remove `DispatchQueue`/`Thread.sleep` polling.
- **Rendering / hardware acceleration:** layer-backed, GPU-composited views; downsample large images; PDFKit page rendering; consider Core Image/Metal for any image processing; ProMotion-friendly (no needless animations; `value`-scoped animations only).
- **Mac-native integration:** rich menu-bar `Commands`, full keyboard navigation & shortcuts, customizable toolbar, Services menu, drag & drop, Quick Look, Spotlight/`CSSearchableItem` indexing (optional), Handoff/Continuity (optional), Share menu.
- **Windowing & state:** SwiftUI `Scene`s, multi-window/tabs where sensible, window state restoration, `SceneStorage`/`AppStorage`.
- **System fit:** Dark mode, Dynamic Type, full VoiceOver/accessibility labels & traits, localization-ready (no hard-coded user strings where avoidable), reduced-motion respect.
- **Security & distribution:** App Sandbox + least-privilege entitlements, security-scoped bookmarks for opened folders, hardened runtime, notarization-ready.
- **Energy & responsiveness:** FSEvents instead of polling; debounced writes; lazy loading; no main-thread disk/network.
- **Cleanup:** delete dead/heavy code as modules are extracted; keep files focused.

---

## Verification discipline
- Build + full test suite green at every step; release bundle via `tools/build-app.sh`.
- New pure logic (cache, watcher invalidation, config parse/round-trip, registry) is unit-tested in the owning framework's tests.
- Performance claims backed by structure (no all-metadata query, cached I/O) and, where possible, an Instruments trace — final "feels fast" confirmation is the user's (no headless UI clicking).
- Honest reporting: what's verified vs. needs manual eyes.
