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

## Phase 1 — Performance: kill the sidebar invalidation storm (IN PROGRESS)
Root cause (audited): `SidebarView` holds `@Query allMeta:[FileMeta]` (every metadata row) and rebuilds `names`/`hiddenPaths` collections on every body eval, threaded **by value** into every row → one tag/notes/hide edit re-renders the whole tree; each re-render reconstructs `FileTreeView`s which re-read the disk via the **uncached** `FileService.enumerate`.
- [ ] **`FileSystemKit` framework:** cached, FSEvents-watched, off-main directory enumeration. Sendable, actor/`@Observable`. Cache invalidated by real filesystem events (no polling).
- [ ] **Stop the storm:** remove the all-metadata `@Query` from the view; maintain a stable, write-through metadata index (path → displayName/hidden) on the model so only the affected row updates. Pass stable references, not freshly-built collections.
- [ ] Verify: build, tests for cache+watcher, Instruments launch trace sanity check.

## Phase 2 — Maximal modularization (`Frameworks/`)
Split the `LumeCore` grab-bag into focused, app-agnostic frameworks; thin `LumeApp`. Right-size to avoid SPM build overhead (use the `spm-build-analysis` skill).
- `FileSystemKit` — FileNode, enumeration, cache, FSEvents watcher.
- `LibraryKit` — SwiftData models (Tag/FileMeta/Favorite), `LibraryStore`, `TagSuggest`, `TagPalette`.
- `DocumentKit` — `FileKind`, `DocumentRouter`, `DisplayName`, `Breadcrumb`, `PathExport`.
- `ConfigKit` — structured config parse/round-trip + pluggable `ConfigFormat` registry (no UI).
- `SelectionKit` — `RowSelection` (+ `SidebarRow` id math).
- `LumeUI` — reusable SwiftUI components (TagChip, FlowLayout, TagField, structured-config editors).
- `LumeApp` — executable: AppModel, scenes, wiring.

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
