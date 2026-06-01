# Lume — Design Spec

> A personal Markdown workspace for macOS.
> Inspiration is split deliberately: **MarkEdit** for the editor surface (its
> styled-source CodeMirror look + native feel) and **Markra** for the sidebar,
> favorites/tags, multi-format viewing, and three-pane layout.
> The name evokes light (lumen) — the app is built around a polished light + dark mode.
> Status: approved design, pre-implementation.
> Date: 2026-06-02

## Purpose

A macOS Markdown-first document workspace that is "perfect for me" — built around
four personal needs:

1. **Favorites + metadata** — pin the folders and files I work in (e.g. `.md` files
   created by Claude skills), and attach tags + a free-text info/notes field to them.
2. **MarkEdit-style Markdown editing** — a styled-source editor (CodeMirror 6): edit
   the raw Markdown, beautifully highlighted (headings sized, bold/italic styled, code
   tinted), with native macOS text behavior. Not WYSIWYG — this is the look I prefer.
3. **`.env` awareness** — recognize and safely view/edit the `.env` files where I
   keep AI coding keys, with value masking.
4. **Multi-format document viewing** — navigate a real working folder and view
   whatever format a document is, not just Markdown. The motivating example is the
   iCloud "Manu Audio LLC" cowork folder: per-client folders each with a `_client.md`
   plus dated project folders of invoices/expenses/packets in **`.pdf` and `.docx`**,
   a `resume.html`, and the scripts that generate them. Lume must open `.pdf`, `.docx`
   (and other office/image formats), `.html`, and source/code files cleanly.

Explicitly **not** in scope for v1 (intentional cuts, see Decisions):
- No AI features.
- No key vault / secrets manager — keys stay in the `.env` files on disk.
- No app sandbox.

## Architecture

A **hybrid native + web** app: a native SwiftUI shell that wraps a CodeMirror 6 editor
surface for the document itself. This mirrors how MarkEdit is built — CodeMirror 6 in a
WKWebView for MarkEdit-grade styled-source editing (multi-caret, code folding, GFM
correctness, performance) — while keeping file management, favorites, tags, multi-format
viewing, and window chrome fully native (Markra-style).

### Three-pane layout (Markra-style)

```
┌──────────────┬────────────────────────────┬──────────────┐
│ Library      │ Document surface           │ Info panel   │
│ (SwiftUI)    │ (router → right viewer)    │ (SwiftUI)    │
│              │                            │ (toggleable) │
│ • Favorites  │  .md  → CodeMirror source │ Tags: ...    │
│ • Tag filter │  .pdf → PDFKit            │ Notes: ...   │
│ • File tree  │  .docx→ QuickLook         │              │
└──────────────┴────────────────────────────┴──────────────┘
```

- **Left — Library sidebar (SwiftUI):** Favorites (pinned folders & files), a tag
  filter, and the file tree of the currently opened folder. Claude-skill `.md` files,
  `.env` files, and the iCloud cowork folder surface here. The tree filters out noise
  (`.DS_Store`, `node_modules`, dotfiles except `.env*`).
- **Center — Document surface (router):** a `DocumentRouter` picks the right viewer for
  the selected file — CodeMirror 6 styled-source for Markdown, PDFKit for PDF, QuickLook
  for `.docx`/office/images, WKWebView for HTML, a read-only code view for source files.
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

3. **FileService** — filesystem access: open a folder, enumerate its tree (with noise
   filtering), read/write a file's text, and detect file type. Non-sandboxed: direct
   path access, user grants folders via the open panel. Interface returns plain values;
   no UI concerns.
   - `FileKind` detection drives routing:
     - `.markdown` — `.md`, `.markdown` → editable (CodeMirror styled-source)
     - `.env` — `.env`, `.env.*` → editable (code/mask mode)
     - `.pdf` → preview (PDFKit)
     - `.previewable` — `.docx`, other office, images, etc. → preview (QuickLook)
     - `.html` → preview (WKWebView)
     - `.code` — `.js/.ts/.py/.json/.yml/.sh/.csv/.txt`… → read-only code view
     - `.unsupported` → QuickLook fallback or "open in Finder"
   - **iCloud-aware:** the cowork folder lives under `com~apple~CloudDocs`, so files may
     be evicted placeholders. `FileService` reads via `NSFileCoordinator`, triggers
     `startDownloadingUbiquitousItem` when needed, and surfaces download state to the UI.

4. **DocumentRouter** — given a `FileKind`, instantiates/selects the correct viewer and
   owns the active-document lifecycle. The single switchboard between the sidebar
   selection and the center surface. Editable kinds go through `EditorBridge`; preview
   kinds go to native viewers.

5. **EditorBridge** — the SwiftUI ↔ WKWebView boundary for **editable** docs. Loads text
   into the CodeMirror editor, requests the current text back, and receives **debounced**
   change events that trigger a disk write via `FileService`. Also pushes the active
   color scheme into the editor. `WKScriptMessageHandler` + `evaluateJavaScript`.

6. **PreviewSurface** — native read-only viewers, no editor JS:
   - **PDFView** (PDFKit) for `.pdf`.
   - **QLPreviewView** (QuickLook) for `.docx` / office / images / long-tail formats —
     renders without any parsing library.
   - HTML routes to a plain WKWebView (a separate, content-only web view — not the
     CodeMirror editor).

7. **WebEditor (bundled JS)** — a small local web app bundled in app resources (no
   network), built entirely on **CodeMirror 6** — one engine, three configurations:
   - **Markdown mode:** styled-source à la MarkEdit — GFM grammar, headings sized,
     bold/italic styled, code blocks tinted, fenced-code language highlighting.
   - **`.env` mode:** key=value view with a **mask-values** toggle (dots by default;
     click a row to reveal/copy).
   - **read-only code mode:** syntax highlighting for source files, no editing.

8. **InfoPanel** — SwiftUI view editing the selected file's `FileMeta` (tags + notes).

## Data flow

- **Select file:** sidebar → `FileService.detectKind(path)` → `DocumentRouter` picks the
  viewer.
  - editable (`.md` / `.env` / code): `FileService.read` → `EditorBridge.load(text, mode)`
    → CodeMirror renders in the matching mode.
  - preview (`.pdf` / `.docx` / html / image): `DocumentRouter` hands the file URL to the
    matching `PreviewSurface` viewer (PDFKit / QuickLook / WKWebView).
- **Edit (editable kinds only):** user types → WebEditor emits a debounced change →
  `EditorBridge` → `FileService.write(path, text)`. Files stay canonical on disk.
  Preview kinds are read-only in v1.
- **Favorite:** user pins a folder/file → `LibraryStore` inserts a `Favorite` row.
- **Tag / annotate:** InfoPanel edits → `LibraryStore` upserts `FileMeta` keyed by path
  (works for any kind — you can tag a PDF or docx, not just Markdown).
- **Filter by tag:** sidebar queries `LibraryStore` for `FileMeta` matching a `Tag`.

## Why CodeMirror 6 styled-source (not WYSIWYG)

The earlier design used Milkdown for true inline WYSIWYG; this is a deliberate reversal.
MarkEdit's styled-source look is the preferred feel, and CodeMirror 6 is the same engine
MarkEdit uses — proven for GFM correctness, multi-caret, code folding, and performance.
Choosing it also **unifies the entire web surface on one engine**: Markdown, `.env`, and
read-only code views are all CodeMirror configurations, instead of Milkdown *plus*
CodeMirror. Simpler, faster, more native — and it edits the canonical `.md` text directly,
so round-tripping is a non-issue (there is no rich model to serialize).

Inspiration, not copying: MarkEdit is open source (CodeMirror 6 + `ts-gyb`), so its editor
config and theming are a reference, but Lume's editor setup, bridge, and styling are
written fresh.

## Look & feel

Clean, design-forward, and minimal. Two references, split by area: **MarkEdit** sets the
editor surface — calm, typographic styled-source Markdown with native macOS text behavior;
**Markra** sets the shell — generous whitespace, minimal chrome, adjustable writing width /
font size / line height, and the three-pane layout.

**Light + dark mode is a first-class design pillar, not an afterthought** (the name
"Lume" leans into it). The native shell uses standard macOS materials so it feels at
home and follows the system appearance automatically; the CodeMirror surface is themed
in lockstep — the SwiftUI side pushes the active color scheme into the editor so the
document never flashes the wrong theme. Both themes are hand-tuned (Markdown syntax
styling, code highlighting palettes) rather than auto-inverted.

## Decisions (with rationale)

- **CodeMirror 6 styled-source, not WYSIWYG** — matches MarkEdit's preferred look,
  unifies the whole web surface on one engine, edits canonical `.md` directly. (Reverses
  an earlier WYSIWYG/Milkdown choice.)
- **Hybrid native+web, not pure SwiftUI** — MarkEdit-grade styled-source editing is best
  done in CodeMirror 6 inside a WKWebView, exactly as MarkEdit does it.
- **PDFKit + QuickLook for non-Markdown viewing** — native, free, and gorgeous;
  QuickLook renders `.docx`/office/long-tail formats with zero parsing libraries. This
  keeps multi-format viewing "simple but premium" instead of pulling in a docx parser.
- **Preview formats are read-only in v1** — viewing PDFs/docx/html is the need; editing
  them is out of scope (and `.docx` editing would mean a heavy dependency).
- **No rendered Markdown preview in v1** — the styled-source surface is the experience;
  inline KaTeX/Mermaid rendering would require a separate preview pane (parked as later).
- **SwiftData for metadata** — modern native persistence; files stay untouched on disk.
- **App sandbox OFF (v1)** — personal tool; avoids the security-scoped-bookmark dance.
  Revisit only if App Store distribution is ever wanted.
- **AI cut (v1)** — not in the feature list; "simple" is the goal. The web-based editor
  makes a future AI side panel easy to add.
- **No key vault (v1)** — keys live in `.env` files; we only view/edit them safely.

## Testing

Swift Testing for the native core:
- `LibraryStore` — CRUD + upsert for `Favorite`, `Tag`, `FileMeta`; tag filtering.
- `FileService` — read/write round-trip; tree enumeration with noise filtering;
  `FileKind` detection across `.md` / `.env.*` / `.pdf` / `.docx` / `.html` / code / other.
- `DocumentRouter` — maps each `FileKind` to the expected viewer (editable vs preview).
- `.env` parsing + masking logic (key=value split, reveal/mask state).
- `EditorBridge` — light smoke test of the load/change/write loop.

Manual verification for v1: CodeMirror Markdown styling in light + dark, and opening the
real iCloud cowork folder to confirm PDF/docx/html render and iCloud download works.

## Out of scope for v1 (possible later)

- Rendered Markdown preview pane (split live-preview with KaTeX math + Mermaid diagrams),
  toggleable beside the styled-source editor — like MarkEdit's preview extension.
- AI side panel (polish / rewrite / continue / summarize / translate).
- Encrypted key vault with Keychain / Touch ID.
- App sandboxing + security-scoped bookmarks.
- Editing non-Markdown formats (PDF / `.docx` / HTML are view-only in v1).
- Export to HTML / PDF.
- Custom CSS themes import/export.
