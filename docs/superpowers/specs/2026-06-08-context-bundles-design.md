# Context Bundles — Design Spec

**Date:** 2026-06-08
**Status:** Approved for planning
**Phase:** 1 of 4 in the "Context Cockpit" roadmap (Context Bundles → Token-budget surfacing → Diff + Propagate → Activity feed)

## Problem

Lume has become a control panel for the config/context files users feed to AI agents (`CLAUDE.md`, `memory.md`, `.env`, `.json`, `.yaml` scattered across many projects). The Scans feature sweeps these files and hands off to an agent — but the existing "copy" actions only export **paths**, never file **contents**:

```swift
// PathExport.promptString today
"Improve these files:\n" + paths.joined("\n")
```

The whole point of handing config to a chatbot is the text inside. Users still open each file and copy/paste manually. Context Bundles completes the Scans→handoff loop: assemble selected files' **contents** into one pasteable blob, and optionally save that set for reuse.

## Goals

1. **Copy as Context** — turn a browser multi-selection or a Scan's ticked set into a single clipboard blob containing each file's contents, wrapped in a chosen format, with a live token estimate.
2. **Saved bundles** — name a set of files, reopen and re-copy later.
3. **Secret safety** — warn before inlining `.env`/secret contents into a paste.

## Non-Goals (v1)

- No real model-specific tokenizer (use `chars/4` approximation).
- No truncation of huge files (estimate still warns; truncation is a later concern).
- No editing of file contents from the bundle view (it links to existing editors).
- No drag-reordering of files within a bundle (sortIndex exists for future use).

## Format Decision

Two formats, user-selectable via a persisted preference (default **XML**):

**XML-style** (Claude-preferred):
```
<documents>
  <document path="~/proj/CLAUDE.md">
  # Project rules
  Always use TDD...
  </document>
  <document path="~/proj/.env">
  API_KEY=...
  </document>
</documents>
```

**Markdown fences** (portable across ChatGPT/Claude/anything) — each file is a `##` heading followed by a language-tagged code fence:

~~~
## ~/proj/CLAUDE.md
```markdown
# Project rules
Always use TDD...
```

## ~/proj/.env
```bash
API_KEY=...
```
~~~

Paths abbreviate the home directory to `~`. Markdown language tags are inferred by file extension (`.md`→markdown, `.env`→bash, `.json`→json, `.yaml`/`.yml`→yaml, `.toml`→toml, `.py`→python, etc.; unknown → no language tag).

## Architecture

Follows existing conventions exactly — `ContextBundle` mirrors `Scan`, `BundlesRegion` mirrors `ScansRegion`, `BundleView` mirrors `ScanTriageView`, `LibraryStore` bundle CRUD mirrors the shipped Scan CRUD.

### LumeKit (pure, testable logic)

**`ContextBundle` `@Model`** — `/Sources/LumeKit/Library/`
```
id: UUID            // unique
name: String
paths: [String]     // POSIX paths, ordered
sortIndex: Int      // drag-reorder position (future use)
dateAdded: Date
```
Additive SwiftData migration with **property-level defaults** (e.g. `Date.now`, `[]`) — same constraint hit on the `Scan` model: no expression defaults, use fully-qualified `Date.now`.

**`ContextFormat` enum** — `.xml` / `.markdown`. Codable raw value; persisted in `UserDefaults` (default `.xml`).

**`ContextAssembler`** (nonisolated, pure struct/enum) — the heart of the feature.
Input: `[URL]` + `ContextFormat`. Output:
```
struct AssembledContext {
    let text: String         // the pasteable blob
    let tokenEstimate: Int   // ceil(text.count / 4)
    let fileCount: Int       // files successfully read
    let unreadable: [URL]    // skipped (binary/permission/missing)
}
```
- Reads each file as UTF-8; non-UTF-8 / unreadable files are skipped and collected into `unreadable` (never silently dropped).
- XML format wraps each readable file in `<document path="…">…</document>` inside a single `<documents>` root.
- Markdown format emits `## <path>` then a language-fenced code block.
- Empty input → empty text, zero counts.

**`SecretDetector`** (nonisolated, pure) — `func sensitiveFiles(in: [URL]) -> [URL]`.
Flags the `.env` family (reuse existing env-file detection) plus a small static list: `*.pem`, `id_rsa`, names containing `secret` or `credential` (case-insensitive). Returns the subset that is sensitive.

### Lume (app / UI)

**`AppState`** (`@MainActor @Observable`):
- `contextFormat: ContextFormat` — read/write `UserDefaults`.
- `copyAsContext(from source:)` where source is the current multi-selection or a Scan's ticked set:
  1. Gather URLs.
  2. `let sensitive = SecretDetector.sensitiveFiles(in: urls)`.
  3. If non-empty → stage `pendingContextCopy` to drive a confirmation dialog; else assemble + write clipboard immediately.
- `confirmPendingContextCopy()` / `cancelPendingContextCopy()`.
- Bundle CRUD delegated to `LibraryStore`: `createBundle(name:paths:)`, `deleteBundle(_:)`, `renameBundle(_:to:)`, `addPaths(_:to:)`, `removePath(_:from:)`.
- A clipboard write helper that dedupes the `NSPasteboard` write (mirrors the existing pasteboard pattern from Scan copy).

**`LibraryStore`**: `ContextBundle` CRUD mirroring the Scan CRUD shipped on `feat/scans` (fetch sorted by `sortIndex`, unique-by-id, save).

**Sidebar — "Bundles" region** (mirrors `ScansRegion`): lists saved bundles; selecting one routes the detail pane to `BundleView`.

**`BundleView`** (detail pane, simpler than `ScanTriageView`):
- File-list of the bundle's paths, each with display name / icon (reuse existing row rendering).
- Missing files (path no longer on disk) shown with a missing marker and excluded from assembly — reuse the Favorite/Scan revalidation pattern.
- Total token estimate shown.
- **"Copy as Context (~N tokens)"** button (respects current format + secret guard).
- Per-row **remove from bundle**.

**Entry points:**
- Selection context menu: `Copy as Context`, `New Bundle from Selection…`, `Add to Bundle ▸ <existing bundles>`.
- `ScanTriageView`: a `Copy as Context` button beside the existing **Copy Paths**.
- Menu command for `Copy as Context`; a `Context Format ▸ XML / Markdown` radio menu group bound to `contextFormat`.

**Secret guard:** `.confirmationDialog` — *"This includes secrets (.env) — copy anyway?"* → **Copy** / **Cancel**. Triggered by `pendingContextCopy != nil`.

## Data Flow

```
selection / ticked URLs
        │
        ▼
SecretDetector.sensitiveFiles ──► non-empty? ──► confirmationDialog ──► (Cancel ends)
        │                                              │ Copy
        └──────────────────────────────────────────────┘
        ▼
ContextAssembler(urls, format) ──► AssembledContext ──► NSPasteboard.writeString(text)
```

## Error Handling & Edge Cases

| Case | Behavior |
|------|----------|
| Binary / non-UTF-8 file | Skipped, surfaced in `unreadable`; UI notes "N files couldn't be read." |
| Bundle references a deleted file | Shown as missing in `BundleView`, excluded from assembly. |
| Empty selection / empty bundle | Copy action disabled. |
| Very large file | No truncation v1; token estimate still shown as the warning signal. |
| Permission denied reading file | Treated as unreadable. |
| Duplicate paths in selection | Deduped before assembly. |

## Testing

**`ContextAssembler` (Swift Testing):**
- XML wrapping structure (single `<documents>` root, per-file `<document path>`).
- Markdown wrapping + language inference (`.md`→markdown, `.json`→json, unknown→no tag).
- Token estimate = `ceil(chars/4)`.
- Home abbreviation to `~`.
- Unreadable/non-UTF-8 file collected into `unreadable`, not in `text`.
- Empty input → empty text, zero counts.

**`SecretDetector`:**
- `.env`, `.env.local`, `*.pem`, `id_rsa` flagged.
- `CLAUDE.md`, `config.json` not flagged.

**`LibraryStore`:**
- `ContextBundle` CRUD round-trip; ordering by `sortIndex`.
- In-memory `ModelContainer` retained for the whole test body (`withExtendedLifetime`) — the SwiftData SIGTRAP lesson.

**`AppState`:**
- `copyAsContext` gathers from a browser selection and from a Scan ticked set.
- Sensitive files → `pendingContextCopy` set (no immediate clipboard write).
- `confirmPendingContextCopy` writes clipboard; `cancel` does not.
- Bundle CRUD reflected in state.

## Implementation Notes

- Keep `PathExport` as-is for path-only copy; `ContextAssembler` is the new contents path. Do not overload `PathExport`.
- `ContextAssembler` and `SecretDetector` are `nonisolated`/pure so they can run off-main and be unit-tested without the app.
- Schema registration: add `ContextBundle` to the same `ModelContainer` schema list as `Scan`, `Tag`, `FileMeta`, etc.

## Followups (out of scope for Phase 1)

- Real tokenizer for accurate counts.
- Truncation / size cap with a "trim to fit budget" affordance (feeds Phase 2: Token-budget surfacing).
- Drag-reorder files within a bundle (sortIndex already reserved).
- Redact-secret-values mode (feeds the Secrets & Safety direction).
