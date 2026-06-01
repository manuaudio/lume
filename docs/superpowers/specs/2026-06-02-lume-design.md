# Lume — Design Spec

> A personal Markdown workspace for macOS, inspired by Markra's GUI.
> The name evokes light (lumen) — the app is built around a polished light + dark mode.
> Status: approved design, pre-implementation.
> Date: 2026-06-02

## Purpose

A macOS Markdown editor that is "perfect for me" — built around three personal needs:

1. **Favorites + metadata** — pin the folders and files I work in (e.g. `.md` files
   created by Claude skills), and attach tags + a free-text info/notes field to them.
2. **True WYSIWYG Markdown editing** — the Markra feel: type and Markdown renders
   inline (math, diagrams, tables, code).
3. **`.env` awareness** — recognize and safely view/edit the `.env` files where I
   keep AI coding keys, with value masking.

Explicitly **not** in scope for v1 (intentional cuts, see Decisions):
- No AI features.
- No key vault / secrets manager — keys stay in the `.env` files on disk.
- No app sandbox.

## Architecture

A **hybrid native + web** app: a native SwiftUI shell that wraps a web-based editor
surface for the document itself. This is the deliberate way to get Markra's true
inline WYSIWYG (which has no good pure-SwiftUI equivalent) while keeping file
management, favorites, tags, and window chrome fully native.

### Three-pane layout (Markra-style)

```
┌──────────────┬────────────────────────────┬──────────────┐
│ Library      │ Document surface           │ Info panel   │
│ (SwiftUI)    │ (WKWebView → Milkdown)     │ (SwiftUI)    │
│              │                            │ (toggleable) │
│ • Favorites  │  # Heading                 │ Tags: ...    │
│ • Tag filter │  rendered inline WYSIWYG   │ Notes: ...   │
│ • File tree  │  math / mermaid / tables   │              │
└──────────────┴────────────────────────────┴──────────────┘
```

- **Left — Library sidebar (SwiftUI):** Favorites (pinned folders & files), a tag
  filter, and the file tree of the currently opened folder. Claude-skill `.md` files
  and `.env` files surface here.
- **Center — Document surface (WKWebView + Milkdown):** true inline WYSIWYG. Renders
  KaTeX math, Mermaid diagrams, GFM tables, and code highlighting in place.
- **Right — Info panel (SwiftUI, toggleable):** tags + a free-text notes/info field
  bound to the selected file's metadata.

## Components

Each component has one clear purpose, a defined interface, and is independently testable.

1. **AppShell** — SwiftUI `App` / window scene, `NavigationSplitView`, menu commands
   (open folder, toggle info panel, etc.). Owns layout; delegates everything else.

2. **LibraryStore (SwiftData)** — the metadata layer. Files on disk are never mutated
   by it; metadata is keyed by file path.
   - `Favorite` — `path: String`, `kind: .file | .folder`, `dateAdded: Date`.
   - `Tag` — `name: String` (unique), relationship to `FileMeta`.
   - `FileMeta` — `path: String` (unique key), `tags: [Tag]`, `info: String` (notes).
   - Upsert semantics: tagging/annotating a file creates its `FileMeta` lazily.

3. **FileService** — filesystem access: open a folder, enumerate its tree, read/write a
   file's text, and detect file type. Non-sandboxed: direct path access, user grants
   folders via the open panel. Interface returns plain values; no UI concerns.
   - `FileKind` detection: `.markdown` (`.md`, `.markdown`), `.env` (`.env`, `.env.*`),
     `.other`.

4. **EditorBridge** — the SwiftUI ↔ WKWebView boundary. Loads a document's text into the
   web editor, requests the current Markdown back, and receives **debounced** change
   events that trigger a disk write via `FileService`. Implemented with
   `WKScriptMessageHandler` + `evaluateJavaScript`.

5. **WebEditor (bundled JS)** — a small local web app, bundled in the app resources
   (no network). Two modes:
   - **Markdown mode:** Milkdown (ProseMirror-based, Markdown-first) with plugins for
     GFM, math (KaTeX), Mermaid, and code highlighting.
   - **`.env` code mode:** a CodeMirror key=value view with a **mask-values** toggle
     (values shown as dots by default; click a row to reveal/copy).

6. **InfoPanel** — SwiftUI view editing the selected file's `FileMeta` (tags + notes).

## Data flow

- **Open file:** `FileService.read(path)` → `EditorBridge.load(text, kind)` →
  WebEditor renders. For `.env`, the editor opens in code mode.
- **Edit:** user types → WebEditor emits a debounced change → `EditorBridge` receives
  current Markdown → `FileService.write(path, text)`. Files stay canonical on disk.
- **Favorite:** user pins a folder/file → `LibraryStore` inserts a `Favorite` row.
- **Tag / annotate:** InfoPanel edits → `LibraryStore` upserts `FileMeta` keyed by path.
- **Filter by tag:** sidebar queries `LibraryStore` for `FileMeta` matching a `Tag`.

## Why Milkdown (not TipTap)

Both are ProseMirror-based. Milkdown is **Markdown-first** — it round-trips to clean
`.md` by design, which is exactly the requirement here. TipTap is HTML-first and
would need fighting to preserve clean Markdown on disk.

## Look & feel

Clean, design-forward, and minimal — Markra's aesthetic as the reference: generous
whitespace, minimal chrome, adjustable writing width / font size / line height.

**Light + dark mode is a first-class design pillar, not an afterthought** (the name
"Lume" leans into it). The native shell uses standard macOS materials so it feels at
home and follows the system appearance automatically; the WKWebView surface is themed
in lockstep — the SwiftUI side pushes the active color scheme into the web editor so
the document never flashes the wrong theme. Both themes are hand-tuned (typographic
contrast, code/diagram palettes) rather than auto-inverted.

## Decisions (with rationale)

- **Hybrid native+web, not pure SwiftUI** — true inline WYSIWYG Markdown has no good
  native library; embedding Milkdown in a WKWebView is the pragmatic, proven path.
- **Milkdown for the editor** — Markdown-first round-tripping.
- **SwiftData for metadata** — modern native persistence; files stay untouched on disk.
- **App sandbox OFF (v1)** — personal tool; avoids the security-scoped-bookmark dance.
  Revisit only if App Store distribution is ever wanted.
- **AI cut (v1)** — not in the feature list; "simple" is the goal. The web-based editor
  makes a future AI side panel easy to add.
- **No key vault (v1)** — keys live in `.env` files; we only view/edit them safely.

## Testing

Swift Testing for the native core:
- `LibraryStore` — CRUD + upsert for `Favorite`, `Tag`, `FileMeta`; tag filtering.
- `FileService` — read/write round-trip; `FileKind` detection across `.md` / `.env.*` / other.
- `.env` parsing + masking logic (key=value split, reveal/mask state).
- `EditorBridge` — light smoke test of the load/change/write loop.

The bundled JS editor is verified manually for v1 (rendering of math/mermaid/tables).

## Out of scope for v1 (possible later)

- AI side panel (polish / rewrite / continue / summarize / translate).
- Encrypted key vault with Keychain / Touch ID.
- App sandboxing + security-scoped bookmarks.
- Export to HTML / PDF.
- Custom CSS themes import/export.
