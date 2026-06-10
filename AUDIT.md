# Lume Codebase Audit — 2026-06-10

Full audit across five dimensions: correctness, security, concurrency/state, architecture/quality, and test coverage. ~60 first-party source files (Sources/Lume app layer + Sources/LumeKit framework) plus 24 test files reviewed by parallel audit agents; every finding below was verified against the actual code before inclusion. Test suite status at audit time: **150/150 passing in 0.15s**.

## Resolution status (branch `audit-fixes`, 2026-06-10)

All findings below were addressed on the `audit-fixes` branch per `docs/superpowers/plans/2026-06-10-audit-fixes.md` (see its "Coverage map" section for the finding → task mapping). Each fix was spot-verified against the code; the full test suite passes. **Audit correction discovered during execution:** the plist CDATA finding (§3) was overstated — Apple's `XMLParser` falls back to `foundCharacters` when no `foundCDATA` handler is set, so content was not actually lost; the explicit handler added in `6c1cbf3` is defensive (that fallback is undocumented).

| Finding | Status | Where |
|---|---|---|
| C1 stale async load saves A into B | Fixed | `e28a3ef` guard stale document loads with selection generation |
| C2 mergeTags prunes unrelated empty tags | Fixed | `02c7c2d` mergeTags no longer prunes unrelated empty tags |
| C3 YAML round-trip retypes strings | Fixed | `25c1316` quote YAML strings whose plain form would change type |
| C4 JSON surrogate-pair escapes rejected | Fixed | `0f583ec` JSON surrogate pairs, strict number grammar, depth cap |
| C5 HTMLViewer executes JavaScript | Fixed | `628a89f` disable JS and lock navigation in HTMLViewer |
| C6 DirectoryWatcher use-after-free | Fixed | `3ea1ab0` retain FSEvents sink and drain queue on teardown |
| A1 AppState god object | Deferred | follow-up decomposition plan |
| A2 all saves are `try?` (silent loss) | Fixed | `74540c4` log and surface SwiftData save failures |
| A3 corrupt-store fallback silent/`try!` | Fixed | `9fca6d3` corrupt-store recovery with visible degraded modes |
| A3b no versioned schema | Fixed | `6486505` versioned SwiftData schema + migration plan |
| A4 FileProvider/FileID abstraction | Deferred | follow-up plan (before remote backends) |
| Plist `<data>`/`<date>` retyped; CDATA | Fixed | `6c1cbf3` native round-trip + CDATA handler; `2256c14` (finding overstated, see note above) |
| TOML dates retyped; bad numbers → `0` | Fixed | `be93da9` native date round-trip; throw on unparseable numbers |
| JSON number grammar + recursion depth | Fixed | `0f583ec` (same commit as C4) |
| EnvFile CRLF parsing | Fixed | `dcc40bf` splits on `isNewline`; EnvFile test suite added |
| SecretDetector filename/content gaps | Fixed | `7a6d5b7` content scan + broader filename coverage |
| Pasteboard secrets unconcealed | Fixed | `8dd232d` `org.nspasteboard.ConcealedType` via `Pasteboard.write(_:concealed:)` |
| recomputeSyncStatus staleness | Fixed | `5b6142c` syncGeneration token guard |
| Overwrite-all blocks main actor | Fixed | `529a421` off-main via testable `CanonicalOverwrite` in LumeKit |
| Watcher main-thread work per batch | Fixed | `4b0ceb6` FSEvents bursts off main; skip untracked refreshes |
| ScanTriage/Bundle/Diff stale tasks | Fixed | `88a15ac` + `d812089` `detachedValue` stale-guard helper |
| Notes popover cross-file write | Fixed | `dc63d4b` saves against the URL it loaded from |
| ⌘Z routing + stale menu enablement | Fixed | `85368ea` responder-chain undo; dedicated editor undo stack |
| Second window nukes navigation state | Fixed | `9fca6d3` first-window launch guard in LumeApp |
| EnvEditor index-captured bindings | Fixed | `0b8120d` bounds + key checks in `bindingForValue` |
| moveToTrash leaves document state stale | Fixed | `3288772` full `closeDocument()` reset on trash |
| save() blocks main actor | Fixed | `7459ca5` coordinated saves off the main actor |
| rename accepts `../` traversal | Fixed | `8dfc224` FileNameValidator + `2d82d80` validation in rename |
| FileService follows symlinks | Fixed | `96817fd` symlinks listed as leaves, never enumerated |
| DocumentRouter vs ContentView drift | Fixed | `a3acdc5` detail pane routes through DocumentRouter |
| Shared read API (6+ raw reads) | Partial | `529a421` moved overwrite reads into LumeKit; full seam deferred to FileProvider plan |
| Error channel doubles as success banner | Fixed | `2050caf` transient notice banner split from errorMessage |
| rename/move orphan path-keyed rows | Fixed | `e5f1307` `repointPath` + `2d82d80` wired into rename |
| Legacy Bookmark CRUD dead code | Fixed | `990413d` CRUD removed; model kept for schema compatibility |
| RowSelection.revalidate drops GROUPS ids | Fixed | `f8c201b` fail-open for GROUPS-grammar row ids |
| Dead code (AppState.files, FileServicing.read/write, TagSuggest) | Fixed | `a7bfd5a` removed |
| Triplicate test fixtures | Fixed | `a3dbffc` one shared full-schema fixture |
| LineDiff/SecretDetector/watcher/EnvFile test gaps | Fixed | `54c2eb9`, `7a6d5b7`, `3ea1ab0`, `dcc40bf` |
| Temp-dir cleanup; home-dir test dependence | Partial | cleanup fixed in `54c2eb9`; home-dir dependence accepted (documented) |
| App Sandbox / Hardened Runtime off | Deferred | documented trade-off for local dev builds |
| FileSystemCache render-time I/O | Deferred | FileProvider plan (documented trade-off) |

---

Severity legend: 🔴 High — data loss/corruption, crash, or security exposure. 🟡 Medium — incorrect behavior or real risk under plausible use. 🔵 Low — latent, edge-case, or hygiene.

---

## 1. Critical & high-severity findings

### 🔴 C1. Stale async load can save file A's contents into file B
`Sources/Lume/AppState.swift:1227-1257` — `choose(_:)` spawns an uncancelled `Task { await select(url) }` per click, and `select` applies `documentText`/`loadedText`/`isDirty` after `await TextDocument.load(url)` **without checking that `selectedURL` still equals the loaded url**. Click a large file A then a small file B: B renders, then A's load completes and overwrites `documentText` while `selectedURL` points at B. One keystroke marks it dirty; ⌘S writes A's contents into B on disk. **Silent data corruption.**
Fix: capture a generation token (or compare `selectedURL == url`) before applying load results; cancel the previous task.

### 🔴 C2. `mergeTags` deletes unrelated empty tags (contract violation, data loss)
`Sources/LumeKit/Library/LibraryStore.swift:304` — `mergeTags` calls `pruneOrphanTags()`, which deletes *every* tag with zero files, not just emptied merge sources. This directly violates the documented contract at lines 224-225 ("Empty tags persist — they are NOT auto-pruned"). Merging any two tags silently destroys all the user's empty groups; merging two empty tags destroys all participants including the survivor.
Fix: prune only the merge-source tags (or none — `renameTag` already removes the merged-away source).

### 🔴 C3. YAML round-trip silently changes string types
`Sources/LumeKit/Config/YAMLConfigFormat.swift:44` — `build(.string(s))` emits a plain unquoted scalar (Yams `plain_implicit=1` drops the `!!str` tag). A string whose text looks like another scalar — `"true"`, `"no"`, `"1.0"`, `"null"`, `"0x1F"` — is written unquoted and re-parses as bool/int/float/null. Open a YAML with `version: "1.0"` in the structured editor, save, and it becomes `version: 1.0`. **One-shot silent type corruption.**
Fix: emit ambiguous strings with explicit quoting style (e.g. `Node(s, Tag(.str), .doubleQuoted)` when the plain form would re-resolve to a non-string).

### 🔴 C4. JSON parser rejects surrogate-pair escapes (valid JSON fails to open)
`Sources/LumeKit/Config/JSONConfigFormat.swift:178` — `parseUnicodeEscape` doesn't handle UTF-16 surrogate pairs. Valid JSON like `"😀"` (how emoji are escaped by `JSONSerialization` and most tools) throws, failing the whole document in the structured editor.
Fix: detect high surrogate, consume the following low surrogate, combine.

### 🔴 C5. HTMLViewer executes JavaScript from arbitrary local files
`Sources/Lume/Viewers/HTMLViewer.swift:9-11` — `WKWebView()` with default config (JS enabled), no navigation delegate, and `allowingReadAccessTo:` widened to the file's parent directory. Opening an attacker-supplied `.html` silently runs its JS, which can beacon out, navigate to remote phishing pages, and read sibling files in the directory. The app runs unsandboxed (project.yml: App Sandbox off), so the blast radius is the whole user account.
Fix: `allowsContentJavaScript = false`; navigation delegate restricting to `file://` for the opened file; pass the file URL itself to `allowingReadAccessTo`.

### 🔴 C6. DirectoryWatcher use-after-free window on teardown
`Sources/LumeKit/FileSystem/DirectoryWatcher.swift:32-46,91-97` — FSEvents context uses `Unmanaged.passUnretained(self)` with no retain/release callbacks; the event callback does `takeUnretainedValue()` on a private queue. `teardown()` doesn't synchronize with an in-flight callback, and `AppState.startWatching` (`AppState.swift:261-262`) drops the last reference right after `stop()`. Opening a new folder while old-root events are in flight can resurrect a deallocated watcher — UB/crash.
Fix: provide retain/release in `FSEventStreamContext` (passRetained semantics) or synchronously drain the queue during teardown.

### 🔴 A1. AppState is a god object (20% of the codebase)
`Sources/Lume/AppState.swift` — 1,280 lines, one `@Observable` class, ~26 MARK sections, ≥14 responsibilities (browsing, selection, favorites, tags, notes, file ops + undo, scans, canonical sync, copy-as-context, bundles, document lifecycle, activity, clipboard). Untestable as-is — and indeed entirely untested.
Fix: split into feature stores composed under a thin AppState; move pure logic (overwrite, sync comparison) into LumeKit where it can be unit-tested.

### 🔴 A2. All 24 persistence saves are `try?` — silent library data loss
`Sources/LumeKit/Library/LibraryStore.swift` — every `context.save()` is `try?`. Favorites, tags, notes, scans, and bundles can all silently fail to persist with zero feedback or logging.
Fix: one throwing `save()` helper; log via `os.Logger`; surface a non-fatal banner.

### 🔴 A3. Corrupt-store fallback is silent and crash-prone; no schema versioning
`Sources/Lume/LumeApp.swift` — on store corruption the app falls back to an in-memory container via `try!` (second failure = launch crash) and never tells the user their library is now ephemeral, nor preserves the corrupt store. No `VersionedSchema`/`SchemaMigrationPlan` (Models.swift comments admit prior launch crashes from this).
Fix: adopt VersionedSchema now (6 models, cheap); move corrupt store aside with user-visible notice; remove `try!`.

### 🔴 A4. Remote-backend roadmap collides with seven local-FS coupling points
LumeKit-wide — planned SSH/GitHub backends are blocked by: (1) `FileNode.id == URL`; (2) absolute path strings as identity everywhere (`FileMeta.path`, `Favorite.path` unique attr, `Scan.roots`, `hiddenPaths`/`expandedPaths` keys, row IDs embedding paths); (3) `FileSystemCache.children(of:)` synchronous `@MainActor` pull from view bodies; (4) `FileServicing` sync protocol; (5) FSEvents-only `DirectoryWatcher`; (6) direct `FileManager` ops in AppState (Trash/undo semantics don't exist remotely); (7) `TextDocument` baking in `NSFileCoordinator` + security-scoped bookmarks in Preferences.
Fix: introduce opaque `FileID` (backend + stable key) and an async FileProvider protocol **before** more path-keyed rows accumulate in SwiftData.

---

## 2. Medium-severity findings

### Correctness
- 🟡 `Sources/LumeKit/Config/PlistConfigFormat.swift:120` — `<data>`/`<date>` parse to `.string` and serialize back as `<string>`: structured edits silently change plist value types.
- 🟡 `Sources/LumeKit/Config/TOMLConfigFormat.swift:44-46` — TOML date/time values round-trip as quoted strings (`released = 2024-06-01` → `released = "2024-06-01"`), contradicting the in-code "stable round-trip" comment.
- 🟡 `Sources/LumeKit/Config/EnvFile.swift:25-37` — splits on `"\n"` and trims with `.whitespaces` (no `\r`): CRLF `.env` files get trailing `\r` in every value, quote-stripping fails, and blank lines misclassify as comments.

### Security
- 🟡 `Sources/LumeKit/Document/SecretDetector.swift:11-19` — filename-only detection misses `*.key`, `*.p8`, `*.p12`/`*.pfx`/`*.jks`, `.netrc`, `.npmrc`, `.pgpass`, `*.ppk`, and any secret *inside* a normal config/source file. Bulk "Copy as Context" can ship an AWS key in `config.json` with no warning. Add the missing patterns + a lightweight content scan (`AKIA`, `-----BEGIN`, `ghp_`, `xox[baprs]-`, `sk-`, high-entropy strings).
- 🟡 `Sources/Lume/Viewers/EnvEditorView.swift:64-66`, `AppState.swift:1034-1038,1161-1164` — secrets and assembled context written to `NSPasteboard.general` as plain `.string`; clipboard managers persist them and Universal Clipboard syncs them across devices. Use `org.nspasteboard.ConcealedType`.
- 🟡 `Sources/LumeKit/Config/JSONConfigFormat.swift:98-148` — hand-rolled recursive parser with no depth limit: a deeply nested `.json` overflows the stack and crashes on open. Cap recursion (~256).

### Concurrency / state
- 🟡 `AppState.swift:1058-1077` — `recomputeSyncStatus()` has no staleness guard (unlike `runScan`'s `scanGeneration`); a stale result can repopulate `syncStatus`/`differingURLs` after the scan was closed — and that feeds the destructive "Overwrite all differing" flow.
- 🟡 `AppState.swift:1097-1134` — `overwrite(_:withCanonical:)` does all reads and coordinated writes synchronously on the main actor; "Overwrite all differing (N)" beachballs the UI.
- 🟡 `AppState.swift:260-274` — watcher callback does per-path `stat` + full `refreshLibrary()` (5 SwiftData fetches + per-file displayName fetches) on main per FSEvents batch; a `git checkout` under the watched root stalls the UI for seconds.
- 🟡 `Sources/Lume/Scans/ScanTriageView.swift:186-209` — `.task(id:)` awaits uncancellable `Task.detached` then assigns without an `isCancelled`/identity check: rapid arrow-keying shows the wrong file's preview. Same pattern in `BundleView.swift:108-125` and `DiffView.swift:74-83` (low).
- 🟡 `Sources/Lume/DocumentTagBar.swift:42-61` — Notes popover saves captured text against whatever URL is current at dismissal: with the popover open, changing selection via keyboard/menu writes file A's notes onto file B. Tie popover identity to the file (`.id(url)`) or save against the URL captured at load.
- 🟡 `Sources/Lume/LumeCommands.swift:25-32` — ⌘Z always routes to the file-ops `UndoManager`: undo while typing re-trashes a file instead of undoing the keystroke; and since `UndoManager` isn't `@Observable`, Undo/Redo menu enablement goes stale.

### Architecture / quality
- 🟡 `DocumentRouter` is unit-tested but `ContentView.DetailView.viewer(for:)` re-implements routing with its own switch — two routing tables that can drift. Make ContentView consume `DocumentRouter`.
- 🟡 Raw `try? String(contentsOf:)` reads in 6+ call sites (sync status, overwrite ×2, ScanTriageView, DiffView, ContextAssembler, FileService.read) bypass coordinated I/O and each swallow errors differently. One shared read API — also the natural seam for the remote-backend refactor.
- 🟡 Single `errorMessage` channel renders as a full-pane view that replaces the document, and is also used for *success* reports ("Overwrote N files…"). Separate a transient banner channel.
- 🟡 `rename`/`duplicate`/`moveToTrash` never migrate path-keyed SwiftData rows: renaming a tagged/annotated/favorited file orphans its tags, notes, and pin. Add `LibraryStore.repointPath(old:new:)`.
- 🟡 Legacy `Bookmark` model: migration made it vestigial but full CRUD API remains with no UI callers. Delete the API; remove the model via versioned migration later.

### Tests
- 🟡 Three near-duplicate `makeStore` helpers across LibraryStore test files, each registering a different model subset, with the SIGTRAP `withExtendedLifetime` workaround copy-pasted into all 25 tests.
- 🟡 `LineDiffTests` are happy-path only (no trailing-newline, multi-hunk, both-empty cases). `SecretDetectorTests` have no false-positive guards (`secretary.md`). `watcherInitAndStopSmoke` asserts nothing — DirectoryWatcher event behavior has zero coverage.
- 🟡 `EnvFile.swift` is fully untested despite a non-trivial parser backing EnvEditorView (and it has the CRLF bug above — a test would have caught it).

---

## 3. Low-severity findings (abridged)

- 🔵 `RowSelection.revalidate` (`RowSelection.swift:106-111`) drops all GROUPS-grammar ids, contradicting its own documented fail-open rule — latent (no production caller yet).
- 🔵 `TOMLConfigFormat.swift:62-64` — unparseable number lexemes silently serialize as `0`; `JSONConfigFormat.swift:193-198` — `parseNumber` accepts garbage like `1.2.3`, producing invalid JSON output.
- 🔵 `PlistConfigFormat.swift:105` — CDATA in plist strings parses to empty string; saving deletes content.
- 🔵 `AppState.rename` (`:844-856`) — `../` in the rename dialog relocates the file out of its directory; reject path separators.
- 🔵 `FileService.swift:28-48` — enumeration follows symlinks (ScanEngine correctly skips them); a symlink to `~/.ssh` inside the opened folder exposes it in the browser.
- 🔵 `LumeApp.swift:34-37` — second window re-runs `attach`/`restoreLastFolder` on the shared AppState, nuking the first window's navigation state.
- 🔵 `EnvEditorView.bindingForValue` (`:73-86`) — index-captured bindings over a reloadable array; out-of-range trap or wrong-key write possible on concurrent reload.
- 🔵 `AppState.moveToTrash` (`:871-893`) — leaves `isDirty`/`loadedText`/`selectedKind` stale after trashing the open document; Save stays enabled but no-ops.
- 🔵 `save()` (`:1269`) — synchronous coordinated write on main; can block arbitrarily for iCloud files (load path already avoids this).
- 🔵 Cache-miss enumeration runs blocking I/O during view render (`browserRows` → `FileSystemCache.children`) — documented trade-off, but unbounded main-thread I/O.
- 🔵 Dead code: `AppState.files` (unused `FileService`), `FileServicing.read/write` (no callers), `TagSuggest` (no app-layer usage).
- 🔵 App runs with App Sandbox and Hardened Runtime off (documented as intentional for local builds) — fine for dev; revisit before distribution.
- 🔵 Untested LumeKit files: EnvFile, Breadcrumb, ContextFormat, DisplayName, GroupSort, VisibleChildrenFilter, DirectoryWatcher (events), GroupRowOrder, TagSuggest. Entire app layer (21 files) untested.
- 🔵 Minor test hygiene: home-directory dependence in one ContextAssembler test; temp dirs without cleanup in two helpers.

**Explicitly checked and clean:** MarkdownHighlighter regexes are linear-time (no ReDoS); LibraryStore persists only paths/tags/notes (never file contents or secret values); TextDocument uses NSFileCoordinator with atomic writes; YAML/TOML parsing uses vetted libraries; ScanEngine bounds depth (64) and skips symlinks; LumeKit↔app layering is clean (no SwiftUI/AppKit in LumeKit, no `@testable` outside tests, no circular deps); zero TODO/FIXME debt; no flaky test patterns.

---

## 4. Architecture summary

Lume is an XcodeGen-managed macOS 14 app split into a SwiftUI app target (`Sources/Lume`) and a genuinely UI-free framework (`Sources/LumeKit`) with Swift 6 strict concurrency. The layering discipline is the codebase's main strength: selection grammars, config round-tripping, scanning, and diffing are pure and well-tested. Its main weakness is the inverse concentration — `AppState` absorbs every feature's state and I/O, and `LibraryStore` silently swallows every persistence failure. Persistence is SwiftData keyed entirely on absolute path strings with no versioned schema, which is fragile against renames and migrations and is the single biggest obstacle to the planned SSH/GitHub backends. Overall health is good for a 0.1: small, documented, tested core; the needed refactors (decompose AppState, harden persistence, abstract the file layer behind async FileProvider + opaque FileID) are well-scoped and not yet entangled.

## 5. Recommended priority order

1. **Fix the two data-corruption races now**: stale-load save (C1) and Notes popover cross-file write (DocumentTagBar) — both silently destroy user file content/notes.
2. **Fix `mergeTags` orphan-pruning (C2)** and add the missing contract test.
3. **Config-format round-trip fixes** (C3 YAML quoting, C4 surrogate pairs, plist data/date, TOML dates, EnvFile CRLF) — these are the app's core value proposition (safe structured editing) and currently corrupt data.
4. **Harden HTMLViewer (C5)** and DirectoryWatcher teardown (C6).
5. **Persistence hardening**: throwing saves, VersionedSchema, corrupt-store recovery, `repointPath` on rename/move.
6. **Before any remote-backend work**: async FileProvider + opaque FileID refactor (A4).
7. Then: decompose AppState, unify routing through DocumentRouter, shared read API, error/banner channel split, ⌘Z routing.
