# Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every concrete finding in `AUDIT.md` (2026-06-10): all data-corruption races, security exposures, persistence hazards, config-format round-trip bugs, and test gaps.

**Architecture:** Lume is an XcodeGen-managed macOS 14 SwiftUI app (`Sources/Lume`) over a UI-free framework (`Sources/LumeKit`, Swift 6 strict concurrency, Swift Testing). Fixes follow the existing layering: pure logic lands in LumeKit with tests; app-layer wiring stays thin. New shared primitives (`Generation`, `detachedValue`, `FileNameValidator`, `Pasteboard`, the `notice` banner channel) are introduced once and reused.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (+ new VersionedSchema), FSEvents, WKWebView, Yams 5.4.0, TOMLKit 0.6.0, Swift Testing (`@Test`/`#expect`), XcodeGen.

**Explicitly out of scope (separate follow-up plan):** AUDIT findings A1 (decompose the 1,280-line AppState into feature stores) and A4 (async FileProvider + opaque FileID for SSH/GitHub backends). Both are whole-subsystem refactors; this plan deliberately avoids pre-empting them while removing every concrete bug. Also deferred: App Sandbox adoption (documented trade-off for local dev builds) and the `FileSystemCache` render-time enumeration trade-off (documented; the async FileProvider plan subsumes it).

---

## Conventions used by every task

- **Regenerate the project whenever a file is added or deleted:** `xcodegen generate`
- **Test command** (fast — full suite runs in ~0.2s): `xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' 2>&1 | tail -5`
- **Build command:** `xcodebuild build -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' 2>&1 | tail -5`
- Test framework is **Swift Testing**: `import Testing`, `@Test func`, `#expect`, `try #require`, `Issue.record`. NOT XCTest.
- The app layer (`Sources/Lume`) has no test target. App-layer tasks end with a "Manual verification" step instead — perform it before committing.
- Every commit message ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Work on a branch: before Task 1, run `git checkout -b audit-fixes`.

**Task order is load-bearing.** Phase 1 primitives are used everywhere; Phase 3's `LumeSchemaV1`, `save(_:)` helper, and `repointPath` are dependencies of Phase 4; `Pasteboard` (Task 25) precedes the SecretDetector integration (Task 26); `ConfigValue`'s new enum cases (Task 27) make five switches non-exhaustive, so Tasks 27–32 land as one compiling sequence.

---

# Phase 1 — Shared foundations

### Task 1: `Generation` — stale-async-completion guard

**Files:**
- Create: `Sources/LumeKit/Generation.swift`
- Test: `Tests/LumeKitTests/GenerationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/GenerationTests.swift`:

```swift
import Testing
@testable import LumeKit

@Test func freshTokenIsCurrent() {
    var gen = Generation()
    let token = gen.advance()
    #expect(gen.isCurrent(token))
}

@Test func advanceInvalidatesEarlierTokens() {
    var gen = Generation()
    let first = gen.advance()
    let second = gen.advance()
    #expect(!gen.isCurrent(first))
    #expect(gen.isCurrent(second))
}

@Test func staleLoadScenarioDropsOnlyTheSupersededCompletion() {
    // Models AUDIT C1: click file A (slow load), then file B before A finishes.
    var gen = Generation()
    let loadA = gen.advance()
    let loadB = gen.advance()
    #expect(!gen.isCurrent(loadA))   // A's late completion must be dropped
    #expect(gen.isCurrent(loadB))    // B's completion applies
}
```

- [ ] **Step 2: Run — expect FAIL (Generation not defined)**

Run: `xcodegen generate && xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' 2>&1 | tail -5`
Expected: build failure, `cannot find 'Generation' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LumeKit/Generation.swift`:

```swift
import Foundation

/// A monotonic generation counter that guards against stale async completions:
/// take a token (`advance()`) before suspending, and apply results only if
/// `isCurrent(token)` after resuming. Any later `advance()` invalidates every
/// earlier token.
public struct Generation: Equatable, Sendable {
    private var value = 0
    public init() {}

    /// Invalidate every outstanding token and return a fresh one.
    @discardableResult
    public mutating func advance() -> Int {
        value += 1
        return value
    }

    /// True while `token` is the latest generation (no `advance()` since).
    public func isCurrent(_ token: Int) -> Bool { token == value }
}
```

- [ ] **Step 4: Run — expect PASS** (same command; all tests green)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Generation.swift Tests/LumeKitTests/GenerationTests.swift Lume.xcodeproj
git commit -m "feat: add Generation counter for stale async completion guards

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `detachedValue` — cancellation-aware detached work helper

**Files:**
- Create: `Sources/LumeKit/DetachedValue.swift`
- Test: `Tests/LumeKitTests/DetachedValueTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/DetachedValueTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeKit

@Suite struct DetachedValueTests {

    @Test func returnsValueWhenNotCancelled() async {
        let v = await detachedValue { 42 }
        #expect(v == 42)
    }

    @Test func defaultsAndPriorityBothDeliver() async {
        let a = await detachedValue(priority: .utility) { "x" }
        #expect(a == "x")
    }

    @Test func returnsNilWhenSurroundingTaskIsCancelled() async {
        // The detached work does NOT inherit cancellation (it's detached), so it
        // completes — but the surrounding task was cancelled, so the helper must
        // discard the value and return nil.
        let task = Task { () -> Int? in
            await detachedValue { () async -> Int in
                // Park long enough for the cancel below to land with margin.
                try? await Task.sleep(for: .milliseconds(200))
                return 42
            }
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'detachedValue' in scope`)

- [ ] **Step 3: Implement**

Create `Sources/LumeKit/DetachedValue.swift`:

```swift
import Foundation

/// Runs `work` off the current actor (via `Task.detached`) and returns its
/// value — or nil if the SURROUNDING task was cancelled while awaiting (e.g. a
/// SwiftUI `.task(id:)` restarted because its id changed, or the view left the
/// hierarchy). Callers treat nil as "stale: do not assign this result to @State".
///
/// The detached work itself is not cancelled (it runs to completion and its
/// value is discarded); the guard protects the ASSIGNMENT, which is what shows
/// the wrong file's data when rapid loads race.
public func detachedValue<T: Sendable>(
    priority: TaskPriority? = nil,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let value = await Task.detached(priority: priority) { await work() }.value
    return Task.isCancelled ? nil : value
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/DetachedValue.swift Tests/LumeKitTests/DetachedValueTests.swift Lume.xcodeproj
git commit -m "feat: add detachedValue helper guarding stale @State assignments

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `FileNameValidator` — reject path separators and traversal in rename input

**Files:**
- Create: `Sources/LumeKit/FileSystem/FileNameValidator.swift`
- Test: `Tests/LumeKitTests/FileNameValidatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/FileNameValidatorTests.swift`:

```swift
import Testing
@testable import LumeKit

@Test func acceptsOrdinaryNames() {
    #expect(FileNameValidator.isValid("notes.md"))
    #expect(FileNameValidator.isValid(".env"))
    #expect(FileNameValidator.isValid("a b c"))
    #expect(FileNameValidator.isValid("notes..md"))   // ".." inside a name is harmless without "/"
}

@Test func rejectsPathSeparatorsAndTraversal() {
    #expect(!FileNameValidator.isValid("a/b"))
    #expect(!FileNameValidator.isValid("../escape"))
    #expect(!FileNameValidator.isValid("/abs"))
    #expect(!FileNameValidator.isValid(".."))
    #expect(!FileNameValidator.isValid("."))
    #expect(!FileNameValidator.isValid(""))
    #expect(!FileNameValidator.isValid("nul\0name"))
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'FileNameValidator' in scope`)

- [ ] **Step 3: Implement**

Create `Sources/LumeKit/FileSystem/FileNameValidator.swift`:

```swift
import Foundation

/// Validates a user-typed file name for same-directory operations (rename).
public enum FileNameValidator {
    /// True if `name` is usable as a single path component: non-empty, no "/"
    /// or NUL, and not a traversal component ("." / ".."). With "/" rejected, a
    /// ".." appearing inside a longer name (e.g. "notes..md") cannot traverse.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.contains("/"), !name.contains("\0") else { return false }
        guard name != ".", name != ".." else { return false }
        return true
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/FileSystem/FileNameValidator.swift Tests/LumeKitTests/FileNameValidatorTests.swift Lume.xcodeproj
git commit -m "feat: add FileNameValidator for rename input

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Notice banner channel — split transient reports from the full-pane error

The single `errorMessage` channel is rendered as a full-pane view that replaces the document, and is also (mis)used for success reports. This task adds a transient `notice` banner. **Channel policy from here on:** `errorMessage` is ONLY for document-open failures (the pane has nothing else to show); everything else uses `showNotice`.

Site migration map for `AppState.errorMessage` (current line numbers):
- `:227` `openFolder` clear → keep, **add** `dismissNotice()`
- `:839` `newFolder` catch → `showNotice` (**this task**)
- `:866` `duplicate` catch → `showNotice` (**this task**)
- `:854` `rename` catch → converted in Task 17 (function is rewritten there)
- `:882` `moveToTrash` catch → converted in Task 18
- `:1099` + `:1131` `overwrite` → converted in Task 20
- `:1277` `save` catch → converted in Task 19
- `:1237`, `:1255` `select` → unchanged (the one true document-open channel)

**Files:**
- Modify: `Sources/Lume/AppState.swift:27-28` (declaration), `:227`, `:839`, `:866`, new `// MARK: - Notices` section
- Modify: `Sources/Lume/ContentView.swift` (overlay + new `NoticeBanner` view)

- [ ] **Step 1: Add the notice channel to AppState**

Replace `Sources/Lume/AppState.swift:27-28`:

```swift
    /// A user-facing, non-fatal error message for the detail pane.
    private(set) var errorMessage: String?
```

with:

```swift
    /// A user-facing, non-fatal error message for the detail pane. Reserved for
    /// document-OPEN failures (when the pane has nothing else to show); all
    /// other reports (file-op failures, save errors, overwrite results) go to
    /// the transient `notice` banner instead.
    private(set) var errorMessage: String?
    /// Transient banner text shown as an overlay over the detail pane.
    /// Auto-clears after a few seconds; never replaces the document.
    private(set) var notice: String?
    @ObservationIgnored private var noticeDismissTask: Task<Void, Never>?
```

Add a new section after the `// MARK: - Internals` block:

```swift
    // MARK: - Notices

    /// Show a transient banner over the detail pane. Auto-clears after
    /// `duration`; showing a new notice resets the clock.
    func showNotice(_ message: String, duration: Duration = .seconds(4)) {
        noticeDismissTask?.cancel()
        notice = message
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Dismiss the banner immediately (✕ button or context switch).
    func dismissNotice() {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        notice = nil
    }
```

- [ ] **Step 2: Migrate this task's sites**

At `:227` (in `openFolder`), after the existing `errorMessage = nil` line, add:

```swift
        dismissNotice()
```

At `:839` (in `newFolder`), replace
`errorMessage = "Couldn't create folder: \(error.localizedDescription)"` with:

```swift
            showNotice("Couldn't create folder: \(error.localizedDescription)")
```

At `:866` (in `duplicate`), replace
`errorMessage = "Couldn't duplicate \(url.lastPathComponent): \(error.localizedDescription)"` with:

```swift
            showNotice("Couldn't duplicate \(url.lastPathComponent): \(error.localizedDescription)")
```

- [ ] **Step 3: Add the banner to ContentView**

Replace the `ContentView` struct in `Sources/Lume/ContentView.swift` (currently lines 5-28; `DetailView` and the rest of the file are untouched):

```swift
struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
                .overlay(alignment: .top) { NoticeBanner() }
                .animation(.easeOut(duration: 0.2), value: app.notice)
        }
        .modifier(ModifierPeekMonitor())
        .confirmationDialog(
            "This selection includes secrets (e.g. .env). Copy their contents anyway?",
            isPresented: Binding(
                get: { app.pendingContextCopy != nil },
                set: { if !$0 { app.cancelPendingContextCopy() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy Anyway", role: .destructive) { app.confirmPendingContextCopy() }
            Button("Cancel", role: .cancel) { app.cancelPendingContextCopy() }
        }
    }
}

/// Transient overlay banner for `AppState.notice` (file-op failures, save
/// errors, overwrite reports). AppState auto-clears it; ✕ dismisses early.
private struct NoticeBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let notice = app.notice {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(notice)
                    .font(.callout)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Button { app.dismissNotice() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

- [ ] **Step 4: Build + manual verification**

Run the build command — expect success. Manual: create a folder with a name that already exists (File ▸ New Folder twice with the same name) → a banner floats over the detail pane, the pane stays visible, and the banner fades after ~4s; ✕ dismisses instantly; two notices back-to-back: the second replaces the first and the clock restarts.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lume/AppState.swift Sources/Lume/ContentView.swift
git commit -m "feat: transient notice banner channel, split from full-pane errorMessage

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 2 — Data-corruption races (AUDIT C1 + stale-write family)

### Task 5: C1 — stale document load can save file A's contents into file B

**Files:**
- Modify: `Sources/Lume/AppState.swift:169-175` (Internals), `:1226-1257` (`choose`/`select`)

- [ ] **Step 1: Implement**

In the `// MARK: - Internals` section (currently `:169-175`), replace:

```swift
    // MARK: - Internals

    private var loadedText: String?
    private let files = FileService()
    /// Main-actor enumeration cache; FSEvents invalidations bump its `revision`.
    let cache = FileSystemCache()
    private var watcher: DirectoryWatcher?
```

with:

```swift
    // MARK: - Internals

    private var loadedText: String?
    /// Guards stale document loads: `select(_:)` applies a finished load only if
    /// no newer selection superseded it while the read was in flight.
    private var selectionGeneration = Generation()
    /// The in-flight document load; cancelled (best-effort) on each `choose`.
    private var loadTask: Task<Void, Never>?
    private let files = FileService()
    /// Main-actor enumeration cache; FSEvents invalidations bump its `revision`.
    let cache = FileSystemCache()
    private var watcher: DirectoryWatcher?
```

(`files` is dead code, removed in Task 36 — keep this diff focused.)

Replace `choose`/`select` (currently `:1226-1257`):

```swift
    /// Choose a file from the sidebar: highlight immediately, then load.
    func choose(_ url: URL) {
        if activeBundle != nil { closeBundle() }
        if activeScan != nil { closeScan() }
        selectedURL = url
        loadTask?.cancel()
        loadTask = Task { await select(url) }
    }

    /// Select a file: load text if it's textual, else mark as non-text.
    func select(_ url: URL) async {
        let token = selectionGeneration.advance()
        selectedURL = url
        errorMessage = nil
        let kind = FileKind.detect(filename: url.lastPathComponent)
        selectedKind = kind
        let isConfig = ConfigRegistry.format(forFilename: url.lastPathComponent) != nil
        guard Self.textEditableKinds.contains(kind) || isConfig else {
            documentText = nil
            loadedText = nil
            isDirty = false
            return
        }
        do {
            let doc = try await TextDocument.load(url)
            // A newer selection (or trash / open-folder) may have superseded this
            // load while it was in flight — applying it then would let one
            // keystroke + ⌘S write file A's contents into file B.
            guard selectionGeneration.isCurrent(token), selectedURL == url else { return }
            documentText = doc.text
            loadedText = doc.text
            isDirty = false
        } catch {
            guard selectionGeneration.isCurrent(token), selectedURL == url else { return }
            documentText = nil
            loadedText = nil
            errorMessage = "Couldn't open \(url.lastPathComponent) as text."
        }
    }
```

- [ ] **Step 2: Build + run full test suite — expect PASS** (Generation guard logic is covered by Task 1's tests)

- [ ] **Step 3: Manual verification**

Open a multi-MB text file A, immediately click a small file B; type one character in B and ⌘S; confirm B on disk contains only B's text + the keystroke (previously it could contain A's text — silent corruption).

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "fix: guard stale document loads with selection generation (AUDIT C1)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Staleness guard for `recomputeSyncStatus`

A stale sync recompute can repopulate `syncStatus`/`differingURLs` after the scan closed — and those feed the destructive "Overwrite all differing" flow.

**Files:**
- Modify: `Sources/Lume/AppState.swift:93-94` (properties), `:1010-1019` (`closeScan`), `:1057-1078` (`recomputeSyncStatus`)

- [ ] **Step 1: Implement**

After the existing properties at `:93-94`:

```swift
    private(set) var isScanning = false
    private var scanGeneration = 0
```

add:

```swift
    /// Guards stale sync recomputes (mirrors what `scanGeneration` does for
    /// `runScan`): a recompute that finishes after the scan closed — or after a
    /// newer recompute started — must not repopulate `syncStatus`, which feeds
    /// the destructive "Overwrite all differing" flow.
    private var syncGeneration = Generation()
```

In `closeScan()` (currently `:1010-1019`), after the `scanGeneration += 1` line, add:

```swift
        syncGeneration.advance()  // discard any in-flight sync recompute
```

Replace `recomputeSyncStatus()` (currently `:1057-1078`):

```swift
    /// Recompute each result's sync status vs the canonical file, off-main.
    func recomputeSyncStatus() async {
        let token = syncGeneration.advance()
        guard let canonicalURL else { syncStatus = [:]; return }
        let canonicalPath = canonicalURL.path
        let results = scanResults.map(\.path)
        let computed = await Task.detached(priority: .utility) { () -> [String: SyncStatus] in
            guard let canonText = try? String(contentsOf: URL(fileURLWithPath: canonicalPath), encoding: .utf8) else {
                return [:]
            }
            var out: [String: SyncStatus] = [:]
            for p in results {
                if p == canonicalPath { out[p] = .canonical; continue }
                if let t = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8) {
                    out[p] = (t == canonText) ? .same : .differs
                } else {
                    out[p] = .unreadable
                }
            }
            return out
        }.value
        guard syncGeneration.isCurrent(token) else { return }  // scan closed / superseded while computing
        syncStatus = computed
    }
```

- [ ] **Step 2: Build + tests — expect PASS**

- [ ] **Step 3: Manual verification**

Run a scan over a large tree with a canonical file set, immediately close the scan while statuses compute; confirm no sync badges / "Overwrite all differing (N)" button reappear for the closed scan.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "fix: staleness guard for recomputeSyncStatus

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Notes popover writes file A's notes onto file B

**Files:**
- Modify: `Sources/Lume/DocumentTagBar.swift:12-62`

- [ ] **Step 1: Implement**

Replace the `body` of `DocumentTagBar` and the whole `NotesPopover` struct (currently `:12-62`):

```swift
    var body: some View {
        let tags = app.tags(forPath: url.path)
        HStack(spacing: 6) {
            ForEach(tags, id: \.name) { tag in
                TagChip(tag: tag) { app.removeTag(tag.name, fromPath: url.path) }
            }
            Button { adding = true } label: {
                Label("Add Tag", systemImage: "tag").font(.caption)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                AddTagPopover(url: url)
                    .id(url)   // reset popover state when the selection changes
            }
            Spacer()
            Button { showingNotes = true } label: {
                Label("Notes", systemImage: app.info(forPath: url.path).isEmpty ? "note.text" : "note.text.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Notes for this file")
            .popover(isPresented: $showingNotes, arrowEdge: .bottom) {
                NotesPopover(url: url)
                    .id(url)   // a selection change replaces (saves + reloads) the popover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Free-text notes (FileMeta.info) for a file. Saved when the popover closes —
/// against the URL the notes were LOADED from, never whatever is selected at
/// dismissal (changing selection with the popover open must not cross-write
/// file A's notes onto file B).
private struct NotesPopover: View {
    let url: URL
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var loadedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
        }
        .padding(12)
        .onAppear {
            if loadedURL == nil {
                text = app.info(forPath: url.path)
                loadedURL = url
            }
        }
        .onDisappear {
            if let loadedURL { app.setInfo(text, forPath: loadedURL.path) }
        }
    }
}
```

- [ ] **Step 2: Build + manual verification**

Open file A's Notes popover, type "for A only"; with the popover open, press ↓ to select file B. Confirm: A's notes contain "for A only", B's notes are unchanged, B's popover state is fresh. Close the popover normally on one file to confirm save-on-dismiss still works.

- [ ] **Step 3: Commit**

```bash
git add Sources/Lume/DocumentTagBar.swift
git commit -m "fix: notes popover saves against the URL it loaded from

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Stale-task `@State` writes in ScanTriageView / BundleView / DiffView

Five sites share the identical pattern: `.task(id:)` awaits an uncancellable `Task.detached`, then assigns `@State` without checking cancellation — rapid navigation shows the wrong file's data. All five adopt `detachedValue` (Task 2).

**Files:**
- Modify: `Sources/Lume/Scans/ScanTriageView.swift:186-209`
- Modify: `Sources/Lume/Bundles/BundleView.swift:108-125`
- Modify: `Sources/Lume/Diff/DiffView.swift:74-83`

- [ ] **Step 1: Implement — ScanTriageView**

Replace `loadSizes`/`loadPreview` (currently `:186-209`):

```swift
    private func loadSizes(_ urls: [URL]) async {
        let paths = urls.map(\.path)
        let computed = await detachedValue(priority: .utility) { () -> [String: Int] in
            var out: [String: Int] = [:]
            for p in paths {
                if let t = TokenEstimator.estimateFile(URL(fileURLWithPath: p)) { out[p] = t }
            }
            return out
        }
        guard let computed else { return } // cancelled: a newer scan-results task owns `sizes`
        sizes = computed
    }

    private func loadPreview(_ url: URL?) async {
        guard let url else { preview = ""; return }
        let text = await detachedValue(priority: .userInitiated) { () -> String in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return "(binary or unreadable file — open in Finder to inspect)"
            }
            if raw.isEmpty { return "(empty file)" }
            let cap = 50_000
            return raw.count > cap ? String(raw.prefix(cap)) + "\n\n… (truncated)" : raw
        }
        guard let text else { return } // cancelled: a newer focus owns `preview`
        preview = text
    }
```

- [ ] **Step 2: Implement — BundleView**

Replace `recomputeEstimate`/`loadSizes` (currently `:108-125`):

```swift
    private func recomputeEstimate() async {
        let urls = existingURLs
        let fmt = app.contextFormat
        let estimate = await detachedValue {
            ContextAssembler.assemble(urls, format: fmt).tokenEstimate
        }
        guard let estimate else { return } // cancelled: a newer estimateKey task owns this
        tokenEstimate = estimate
    }

    private func loadSizes(_ paths: [String]) async {
        let computed = await detachedValue(priority: .utility) { () -> [String: Int] in
            var out: [String: Int] = [:]
            for p in paths {
                if let t = TokenEstimator.estimateFile(URL(fileURLWithPath: p)) { out[p] = t }
            }
            return out
        }
        guard let computed else { return } // cancelled: a newer path set owns `sizes`
        sizes = computed
    }
```

- [ ] **Step 3: Implement — DiffView**

Replace `load()` (currently `:74-83`). Note `result` is `[DiffLine]??` — outer nil = cancelled/stale, inner nil = unreadable; the two-step unwrap preserves both signals:

```swift
    private func load() async {
        let c = canonical, t = target
        let result = await detachedValue(priority: .userInitiated) { () -> [DiffLine]? in
            guard let canonText = try? String(contentsOf: c, encoding: .utf8),
                  let targetText = try? String(contentsOf: t, encoding: .utf8) else { return nil }
            return LineDiff.compute(from: targetText, to: canonText)
        }
        guard let result else { return } // cancelled: a newer canonical/target pair owns `lines`
        if let computed = result { lines = computed; unreadable = false }
        else { lines = []; unreadable = true }
    }
```

- [ ] **Step 4: Build + manual verification**

Open a scan with many files → hold ↓ to arrow-key rapidly → the preview pane always shows the file that ends focused. Same for the size column, the bundle token estimate after rapid format switching, and the diff pane while arrow-keying between differing files.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lume/Scans/ScanTriageView.swift Sources/Lume/Bundles/BundleView.swift Sources/Lume/Diff/DiffView.swift
git commit -m "fix: drop stale detached-task results in triage/bundle/diff views

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: EnvEditorView — index-captured bindings over a reloadable array

**Files:**
- Modify: `Sources/Lume/Viewers/EnvEditorView.swift:73-86`

- [ ] **Step 1: Implement**

Replace `bindingForValue(index:key:)` (currently `:73-86`):

```swift
    private func bindingForValue(index: Int, key: String) -> Binding<String> {
        Binding(
            get: {
                // `lines` can be reloaded (file switch / external change) while a
                // row's binding is still live — re-check bounds and key before use.
                guard lines.indices.contains(index),
                      case let .entry(e) = lines[index], e.key == key else { return "" }
                return e.value
            },
            set: { newValue in
                guard lines.indices.contains(index),
                      case let .entry(e) = lines[index], e.key == key else { return }
                lines[index] = .entry(EnvEntry(key: e.key, value: newValue))
                let text = serialize()
                lastPushed = text
                app.documentTextChanged(text)
            }
        )
    }
```

- [ ] **Step 2: Build + manual verification**

Open a `.env` with ≥5 entries, reveal and focus a value near the bottom, then externally truncate the file (`echo 'A=1' > .env` in Terminal). The app must not crash (old: out-of-range trap) and the stale field must not write into a different key.

- [ ] **Step 3: Commit**

```bash
git add Sources/Lume/Viewers/EnvEditorView.swift
git commit -m "fix: guard env editor bindings against reloaded line arrays

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 3 — Persistence hardening (AUDIT C2, A2, A3, A3b, repointPath)

Order inside this phase is load-bearing: schema → shared fixture → bookmark removal → save helper → mergeTags → repointPath → container factory.

### Task 10: `LumeSchemaV1` + `LumeMigrationPlan` (versioned schema)

**Files:**
- Create: `Sources/LumeKit/Library/LumeSchema.swift`
- Test: `Tests/LumeKitTests/LumeSchemaTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/LumeSchemaTests.swift`:

```swift
import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func versionedSchemaCoversAllSixModels() throws {
    #expect(LumeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    let schema = Schema(versionedSchema: LumeSchemaV1.self)
    let names = Set(schema.entities.map(\.name))
    #expect(names == ["Favorite", "Bookmark", "Tag", "FileMeta", "Scan", "ContextBundle"])
}

@MainActor @Test func containerOpensWithMigrationPlan() throws {
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV1.self),
        migrationPlan: LumeMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    defer { withExtendedLifetime(container) {} }
    // Every model in the plan round-trips.
    let context = container.mainContext
    context.insert(Favorite(path: "/f", kindRaw: "markdown"))
    context.insert(Bookmark(path: "/b"))
    context.insert(Tag(name: "t"))
    context.insert(FileMeta(path: "/m"))
    context.insert(Scan(name: "s", patterns: ["*.md"], roots: ["/r"]))
    context.insert(ContextBundle(name: "c", paths: ["/p"]))
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<ContextBundle>()).count == 1)
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'LumeSchemaV1' in scope`)

- [ ] **Step 3: Implement**

Create `Sources/LumeKit/Library/LumeSchema.swift`:

```swift
import Foundation
import SwiftData

/// Versioned snapshot of the store layout (audit A3b). ALL container creation
/// (app + tests) goes through this so any future model change becomes an
/// explicit `LumeSchemaV2` + migration stage instead of relying on implicit
/// lightweight migration (Models.swift documents prior launch crashes from
/// exactly that).
public enum LumeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self, ContextBundle.self]
    }
}

public enum LumeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [LumeSchemaV1.self] }
    /// Empty: V1 is the first versioned snapshot of the existing layout, so
    /// existing stores adopt it without a stage. The next schema change adds
    /// LumeSchemaV2 and its stage here — that is also where the vestigial
    /// `Bookmark` model finally gets dropped (see LibraryStore bookmark notes).
    public static var stages: [MigrationStage] { [] }
}
```

The V1 model list must stay byte-identical to the current six `@Model` classes — it versions the *existing* layout.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Library/LumeSchema.swift Tests/LumeKitTests/LumeSchemaTests.swift Lume.xcodeproj
git commit -m "feat: versioned SwiftData schema + migration plan (AUDIT A3b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: One shared test fixture (`makeLibrary`) replacing three drifted helpers

**Files:**
- Create: `Tests/LumeKitTests/LibraryTestSupport.swift`
- Modify: `Tests/LumeKitTests/LibraryStoreTests.swift:5-20` (delete old helper + comment), `Tests/LumeKitTests/LibraryStoreScanTests.swift:5-11`, `Tests/LumeKitTests/LibraryStoreBundleTests.swift:5-11` (delete old helpers), plus all 30 call sites

- [ ] **Step 1: Create the shared helper**

Create `Tests/LumeKitTests/LibraryTestSupport.swift`:

```swift
import SwiftData
@testable import LumeKit

// NOTE: `makeLibrary()` returns the `ModelContainer` alongside the store, and
// each test pins it with `defer { withExtendedLifetime(container) {} }` for its
// whole body. `LibraryStore` only holds a `ModelContext`, and on this toolchain
// (Apple Swift 6.3.2, macOS 26 SDK) a `ModelContext` whose owning in-memory
// `ModelContainer` has been deallocated crashes with SIGTRAP on the next
// SwiftData operation. In the real app the container is owned by the SwiftUI
// `.modelContainer` scene for the app's lifetime, so this only affects the test
// helper — hence the lifetime is pinned at call sites rather than changing the
// `LibraryStore(context:)` public API.
//
// The container registers the FULL versioned schema (LumeSchemaV1), never a
// subset: per-file model subsets are what let three helpers drift apart, and
// the app never runs against a partial schema anyway.
@MainActor
func makeLibrary() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    return (LibraryStore(context: container.mainContext), container)
}
```

- [ ] **Step 2: Delete the three old private helpers**

Delete `makeStore()` (and the SIGTRAP comment block above it, `:5-20`) from `LibraryStoreTests.swift`; delete `makeContainer()` from `LibraryStoreScanTests.swift:5-11` and `LibraryStoreBundleTests.swift:5-11`. (Both deletions in the same change — the old helpers were `private`, which is the only reason the duplicate names coexisted.)

- [ ] **Step 3: Migrate all 30 call sites — three mechanical patterns, no other shapes exist**

**Pattern A — tuple `makeStore()` (all 20 tests in LibraryStoreTests.swift).** Replace the token `makeStore()` with `makeLibrary()`; nothing else changes:

```swift
// before
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
// after
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
```

**Pattern B — container-only with raw context (2 tests: `scanModelPersistsFields`, `bundleModelPersistsFields`).** Replace `let container = try makeContainer()` with `let (_, container) = try makeLibrary()`; the following `defer` and `let context = container.mainContext` lines are unchanged:

```swift
// before
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext
// after
    let (_, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext
```

**Pattern C — `makeContainer()` + manual store construction (3 tests: `scanCRUDViaStore`, `scanCanonicalPersists`, `bundleCRUDViaStore`).** Replace the two lines with one; the `defer` between them is unchanged and the `LibraryStore(...)` line is deleted:

```swift
// before
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)
// after
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
```

- [ ] **Step 4: Run full suite — expect PASS (150 tests, none deleted)**

- [ ] **Step 5: Commit**

```bash
git add Tests/LumeKitTests/
git commit -m "refactor: one shared full-schema test fixture for LibraryStore suites

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Remove dead Bookmark CRUD (model stays for schema compatibility)

Verified by grep: `addBookmark`/`reorderBookmarks`/`removeBookmark`/`isBookmarked`/`bookmarks()` have zero callers outside LibraryStore.swift and tests. The only app-layer touchpoint is `migrateBookmarksToFavorites()` (kept). The `@Model` stays in `LumeSchemaV1` — removing it while rows may exist on disk is a schema change deferred to `LumeSchemaV2`.

**Files:**
- Modify: `Sources/LumeKit/Library/LibraryStore.swift:53-105`
- Modify: `Tests/LumeKitTests/LibraryStoreTests.swift` (delete 2 tests, rewrite 2)

- [ ] **Step 1: Replace the Bookmarks section**

Replace `LibraryStore.swift:53-105` (the whole `// MARK: Bookmarks` section: `addBookmark`, `reorderBookmarks`, `removeBookmark`, `isBookmarked`, `bookmarks()`, `bookmark(for:)`, `migrateBookmarksToFavorites`) with:

```swift
    // MARK: Bookmarks (legacy — model retained for schema compatibility only)

    /// One-time migration: every bookmarked folder becomes a folder `Favorite`
    /// (pins unify onto Favorites), then the bookmark table is cleared so this is
    /// idempotent. Returns how many NEW favorites were created.
    ///
    /// This is the ONLY remaining `Bookmark` API — the CRUD surface (add/reorder/
    /// remove/isBookmarked/bookmarks) was dead code and is gone. The `@Model`
    /// itself stays in `LumeSchemaV1` so existing stores keep opening; it gets
    /// dropped in a future `LumeSchemaV2` migration stage.
    @discardableResult
    public func migrateBookmarksToFavorites() -> Int {
        let existing = (try? context.fetch(
            FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
        let base = favorites().count
        var created = 0
        for bm in existing {
            if favorite(for: bm.path) == nil {
                context.insert(Favorite(path: bm.path, kindRaw: "folder",
                                        sortIndex: base + created))
                created += 1
            }
            context.delete(bm)
        }
        try? context.save()
        return created
    }
```

(The `try? context.save()` becomes `save("migrateBookmarksToFavorites")` in Task 13.)

- [ ] **Step 2: Replace the affected tests**

In `LibraryStoreTests.swift`: delete `reorderBookmarksPersistsOrder` (`:22-33`) and `bookmarksAreIndependentOfFavorites` (`:61-81`) — they test only the removed API. Replace the two migration tests with versions that seed legacy rows directly (the model is still in the schema):

```swift
@MainActor @Test func migrateBookmarksBecomeFolderFavorites() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext

    // The Bookmark CRUD API is gone; seed legacy rows directly, exactly as an
    // old store version would have persisted them.
    context.insert(Bookmark(path: "/work", sortIndex: 0))
    context.insert(Bookmark(path: "/docs", sortIndex: 1))
    try context.save()
    store.addFavoriteFolder(path: "/work")   // already favorited too

    let migratedCount = store.migrateBookmarksToFavorites()

    // /docs was bookmark-only -> becomes a folder favorite; /work already was.
    #expect(migratedCount == 1)
    #expect(store.isFavorite(path: "/docs") == true)
    #expect(store.favorites().first { $0.path == "/docs" }?.kindRaw == "folder")
    // Bookmark rows are cleared after migration so it never runs twice.
    #expect(try context.fetch(FetchDescriptor<Bookmark>()).isEmpty)
    #expect(store.migrateBookmarksToFavorites() == 0)
}

@MainActor @Test func migrateAssignsDistinctSortIndexes() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext

    context.insert(Bookmark(path: "/a", sortIndex: 0))
    context.insert(Bookmark(path: "/b", sortIndex: 1))
    try context.save()
    store.migrateBookmarksToFavorites()

    let favs = store.favorites().filter { $0.path == "/a" || $0.path == "/b" }
        .sorted { $0.sortIndex < $1.sortIndex }
    #expect(Set(favs.map(\.sortIndex)).count == 2)          // distinct
    #expect(favs.map(\.path) == ["/a", "/b"])               // stable order
}
```

- [ ] **Step 3: Run full suite — expect PASS**

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeKit/Library/LibraryStore.swift Tests/LumeKitTests/LibraryStoreTests.swift
git commit -m "refactor: remove dead Bookmark CRUD; keep model for schema compatibility

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Logged, observable save helper — no more silent `try? context.save()`

**Files:**
- Modify: `Sources/LumeKit/Library/LibraryStore.swift:1-7` (header) + all 21 remaining save sites
- Modify: `Sources/Lume/ContentView.swift` (persistence-failure banner)
- Test: `Tests/LumeKitTests/LibraryStorePersistenceErrorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/LibraryStorePersistenceErrorTests.swift`:

```swift
import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func successfulSavesLeaveNoPersistenceError() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.addFavorite(path: "/a.md", kind: .markdown)
    store.createEmptyTag(named: "t")
    store.setMeta(path: "/a.md", info: "n", tagNames: ["t"])
    #expect(store.lastPersistenceError == nil)
}

@MainActor @Test func failedSaveSetsAndClearsLastPersistenceError() throws {
    // `allowsSave: false` makes `context.save()` throw deterministically —
    // the only reliable way to force a SwiftData save failure in-memory.
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: false)]
    )
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)

    store.createEmptyTag(named: "doomed")
    let failure = try #require(store.lastPersistenceError)
    #expect(failure.operation == "createEmptyTag")
    #expect(!failure.message.isEmpty)

    store.clearPersistenceError()
    #expect(store.lastPersistenceError == nil)
}
```

(Caveat: if `allowsSave: false` no-ops instead of throwing on this toolchain, substitute a read-only on-disk store fixture.)

- [ ] **Step 2: Run — expect FAIL** (`lastPersistenceError` not defined)

- [ ] **Step 3: Implement the header + helper**

Replace `LibraryStore.swift:1-7`:

```swift
import Foundation
import SwiftData

@MainActor
public final class LibraryStore {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }
```

with:

```swift
import Foundation
import Observation
import SwiftData
import os

/// A persistence save failure, surfaced for the app layer to banner.
/// `LibraryStore` publishes the most recent one via `lastPersistenceError`.
public struct PersistenceFailure: Equatable, Sendable {
    /// The `LibraryStore` operation that failed, e.g. "addFavorite".
    public let operation: String
    /// `localizedDescription` of the underlying SwiftData error.
    public let message: String
    public let date: Date

    public init(operation: String, message: String, date: Date = .now) {
        self.operation = operation
        self.message = message
        self.date = date
    }
}

@MainActor
@Observable
public final class LibraryStore {
    private let context: ModelContext
    private let logger = Logger(subsystem: "com.lume.LumeKit", category: "LibraryStore")

    /// The most recent save failure, or nil. The app layer observes this and
    /// shows a non-fatal banner; `clearPersistenceError()` dismisses it. Only
    /// the LATEST failure is kept — the banner is a "your library may not be
    /// persisting" signal, not an error log (the log is in os.Logger).
    public private(set) var lastPersistenceError: PersistenceFailure?

    public init(context: ModelContext) { self.context = context }

    public func clearPersistenceError() { lastPersistenceError = nil }

    /// Single save funnel: every mutation goes through here so failures are
    /// logged and surfaced instead of silently dropped (audit A2).
    @discardableResult
    private func save(_ operation: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            logger.error("\(operation, privacy: .public) failed to save: \(error.localizedDescription, privacy: .public)")
            lastPersistenceError = PersistenceFailure(operation: operation, message: error.localizedDescription)
            return false
        }
    }
```

- [ ] **Step 4: Convert all 21 save sites**

Mechanical rule: replace `try? context.save()` with `save("<enclosingMethodName>")`, preserving surrounding syntax. Operation names (verbatim method names): addFavorite, addFavoriteFolder, reorderFavorites, removeFavorite, migrateBookmarksToFavorites, setMeta, setHidden, recolorTag, createEmptyTag, removeTag, deleteTag, pruneOrphanTags, renameTag, addScan, updateScan, removeScan, setCanonical, addBundle, renameBundle, setBundlePaths, removeBundle. The three syntactic shapes:

```swift
// 1. statement form:
try? context.save()                                  // → save("addFavorite")
// 2. inline-conditional form (removeFavorite):
if let fav = favorite(for: path) { context.delete(fav) ; try? context.save() }
// → if let fav = favorite(for: path) { context.delete(fav); save("removeFavorite") }
// 3. guarded form (pruneOrphanTags):
if !orphans.isEmpty { try? context.save() }          // → if !orphans.isEmpty { save("pruneOrphanTags") }
```

The `try?` **fetches** in the file are unchanged — A2's scope is saves.

- [ ] **Step 5: Surface it in the UI**

In `Sources/Lume/ContentView.swift`, extend the detail overlay (added in Task 4) to also show persistence failures. Replace the line `.overlay(alignment: .top) { NoticeBanner() }` with:

```swift
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        NoticeBanner()
                        PersistenceErrorBanner()
                    }
                }
```

and add below `NoticeBanner`:

```swift
/// Non-fatal "your library may not be persisting" banner, fed by
/// `LibraryStore.lastPersistenceError` (set by the save funnel).
private struct PersistenceErrorBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let failure = app.library?.lastPersistenceError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("Your library couldn't save (\(failure.operation)): changes may not persist.")
                    .font(.callout)
                    .lineLimit(2)
                Button { app.library?.clearPersistenceError() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

(`AppState.library` is `private(set) var library: LibraryStore?` — already readable. `@Observable` on LibraryStore gives the view change tracking for free.)

- [ ] **Step 6: Run full suite — expect PASS. Build the app — expect success.**

- [ ] **Step 7: Commit**

```bash
git add Sources/LumeKit/Library/LibraryStore.swift Sources/Lume/ContentView.swift Tests/LumeKitTests/LibraryStorePersistenceErrorTests.swift Lume.xcodeproj
git commit -m "fix: log and surface SwiftData save failures (AUDIT A2)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 14: C2 — `mergeTags` must not prune unrelated empty tags

**Files:**
- Modify: `Sources/LumeKit/Library/LibraryStore.swift:289-306` (`mergeTags`)
- Test: append to `Tests/LumeKitTests/LibraryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `LibraryStoreTests.swift`:

```swift
@MainActor @Test func mergeTagsLeavesUnrelatedEmptyTagsAlone() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "keepEmpty")          // unrelated empty group
    store.setMeta(path: "/a", info: "", tagNames: ["one"])
    store.setMeta(path: "/b", info: "", tagNames: ["two"])
    #expect(store.mergeTags(["one", "two"], into: "all", colorIndex: nil))
    // The unrelated empty group survives the merge (GROUPS contract).
    #expect(store.allTags().map(\.name) == ["all", "keepEmpty"])
    #expect(store.paths(taggedWith: "all") == ["/a", "/b"])
}

@MainActor @Test func mergingEmptyTagsKeepsTheSurvivor() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.createEmptyTag(named: "a")
    store.createEmptyTag(named: "b")
    #expect(store.mergeTags(["a", "b"], into: "a", colorIndex: nil))
    // Sources are gone, the (still empty) survivor persists.
    #expect(store.allTags().map(\.name) == ["a"])
    #expect(store.paths(taggedWith: "a").isEmpty)
}
```

- [ ] **Step 2: Run — expect FAIL** (both tests: tags wrongly pruned)

- [ ] **Step 3: Implement**

Replace `mergeTags` (`:289-306`). The only behavioral change is deleting the `pruneOrphanTags()` call; `renameTag`'s merge branch already deletes every source:

```swift
    /// Merge several tags into one. Every file on a source tag is re-pointed onto
    /// `survivor` (de-duped), the chosen `colorIndex` (if any) is applied, and the
    /// source tags are removed by `renameTag` itself (its merge branch deletes the
    /// merged-away source). Built on `renameTag` (which already merges on a name
    /// clash) so the per-file de-dup logic lives in exactly one place.
    /// `survivor` need not pre-exist: the first matching source is renamed to it.
    /// No pruning happens here: unrelated empty tags are untouched, and the
    /// survivor persists even when the merge result has zero files (GROUPS
    /// design, see `createEmptyTag`: empty groups are valid — no auto-prune).
    /// Returns true if the survivor exists after the operation.
    @discardableResult
    public func mergeTags(_ names: [String], into survivor: String, colorIndex: Int?) -> Bool {
        // Fold every other named tag onto the survivor. `renameTag` renames when
        // the survivor is absent and merges when it already exists, so iterating
        // sources naturally creates-then-merges — and deletes each source.
        for name in names where name != survivor {
            _ = renameTag(named: name, to: survivor)
        }
        if let colorIndex { recolorTag(named: survivor, colorIndex: colorIndex) }
        return existingTag(named: survivor) != nil
    }
```

`pruneOrphanTags()` itself stays — only the call from `mergeTags` goes. Existing tests `mergeTagsFoldsFilesAndAppliesColor` and `pruneOrphanTagsRemovesOnlyEmptyOnes` pass unchanged.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Library/LibraryStore.swift Tests/LumeKitTests/LibraryStoreTests.swift
git commit -m "fix: mergeTags no longer prunes unrelated empty tags (AUDIT C2)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 15: `repointPath` — migrate path-keyed rows on rename/move

**Files:**
- Modify: `Sources/LumeKit/Library/LibraryStore.swift` (insert after `displayName(for:)`, ~line 158)
- Test: `Tests/LumeKitTests/LibraryStoreRepointTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/LibraryStoreRepointTests.swift`:

```swift
import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func repointMovesFileMetaAndFavorite() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/p/a.md", info: "note", tagNames: ["work"], displayName: "A")
    store.addFavorite(path: "/p/a.md", kind: .markdown)
    store.setHidden(true, paths: ["/p/a.md"])

    store.repointPath(from: "/p/a.md", to: "/p/renamed.md")

    #expect(store.meta(for: "/p/a.md") == nil)
    let moved = try #require(store.meta(for: "/p/renamed.md"))
    #expect(moved.info == "note")
    #expect(moved.displayName == "A")
    #expect(moved.hidden == true)
    #expect(moved.tags.map(\.name) == ["work"])
    #expect(store.isFavorite(path: "/p/a.md") == false)
    #expect(store.isFavorite(path: "/p/renamed.md") == true)
}

@MainActor @Test func repointDirectoryMovesDescendantsButNotPrefixSiblings() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a/b", info: "dir itself", tagNames: [])
    store.setMeta(path: "/a/b/deep/x.md", info: "descendant", tagNames: [])
    store.setMeta(path: "/a/bc/y.md", info: "prefix sibling", tagNames: [])
    store.addFavoriteFolder(path: "/a/b")

    store.repointPath(from: "/a/b", to: "/a/z")

    #expect(store.meta(for: "/a/z")?.info == "dir itself")
    #expect(store.meta(for: "/a/z/deep/x.md")?.info == "descendant")
    // "/a/bc" merely shares the "/a/b" character prefix — untouched.
    #expect(store.meta(for: "/a/bc/y.md")?.info == "prefix sibling")
    #expect(store.isFavorite(path: "/a/z") == true)
}

@MainActor @Test func repointUpdatesScanRootsCanonicalAndBundlePaths() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    let scan = store.addScan(name: "S", patterns: ["CLAUDE.md"], roots: ["/old/root", "/other"])
    store.setCanonical("/old/root/CLAUDE.md", for: scan)
    let bundle = store.addBundle(name: "B", paths: ["/old/root/CLAUDE.md", "/other/.env"])

    store.repointPath(from: "/old/root", to: "/new/root")

    #expect(scan.roots == ["/new/root", "/other"])
    #expect(scan.canonicalPath == "/new/root/CLAUDE.md")
    #expect(bundle.paths == ["/new/root/CLAUDE.md", "/other/.env"])
}

@MainActor @Test func repointResolvesDestinationClashInFavorOfMovedRow() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/dst.md", info: "stale destination", tagNames: [])
    store.setMeta(path: "/src.md", info: "rich source", tagNames: ["keep"])

    store.repointPath(from: "/src.md", to: "/dst.md")

    let survivor = try #require(store.meta(for: "/dst.md"))
    #expect(survivor.info == "rich source")
    #expect(survivor.tags.map(\.name) == ["keep"])
    #expect(store.meta(for: "/src.md") == nil)
}

@MainActor @Test func repointNoOpsOnDegenerateInput() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "x", tagNames: [])
    store.repointPath(from: "/a.md", to: "/a.md")   // same path
    store.repointPath(from: "", to: "/b.md")        // empty source
    #expect(store.meta(for: "/a.md")?.info == "x")
    #expect(store.lastPersistenceError == nil)
}
```

- [ ] **Step 2: Run — expect FAIL** (`repointPath` not defined)

- [ ] **Step 3: Implement**

Insert after `displayName(for:)` in `LibraryStore.swift`:

```swift
    // MARK: Path repointing

    /// Re-point every path-keyed row from `oldPath` to `newPath` after a rename
    /// or move on disk, so tags, notes, hidden flags, display names, favorites,
    /// scan roots/canonicals, and bundle members survive the operation.
    ///
    /// Scope: ALL path-keyed columns — `FileMeta.path`, `Favorite.path`,
    /// `Scan.roots`, `Scan.canonicalPath`, `ContextBundle.paths` — because the
    /// orphaning bug is identical for each, and a stale `canonicalPath` is the
    /// worst of them (it feeds the destructive overwrite-all flow). The
    /// vestigial `Bookmark` is excluded: its table is emptied at attach by
    /// `migrateBookmarksToFavorites()`.
    ///
    /// Directory moves repoint descendants too: every stored path is an
    /// absolute POSIX string, so "row is under the moved directory" is exactly
    /// a `oldPath + "/"` prefix match ("/a/bc" is NOT under "/a/b").
    ///
    /// If a row already exists at a destination path (its unique attribute
    /// would collide), the destination row is deleted and the moved row wins —
    /// it carries the user's accumulated metadata.
    public func repointPath(from oldPath: String, to newPath: String) {
        guard !oldPath.isEmpty, !newPath.isEmpty, oldPath != newPath else { return }
        let prefix = oldPath + "/"

        func remapped(_ path: String) -> String? {
            if path == oldPath { return newPath }
            if path.hasPrefix(prefix) { return newPath + path.dropFirst(oldPath.count) }
            return nil
        }

        let metas = (try? context.fetch(FetchDescriptor<FileMeta>(
            predicate: #Predicate { $0.path == oldPath || $0.path.starts(with: prefix) }
        ))) ?? []
        for m in metas {
            guard let target = remapped(m.path) else { continue }
            if let clash = meta(for: target) { context.delete(clash) }
            m.path = target
        }

        let favs = (try? context.fetch(FetchDescriptor<Favorite>(
            predicate: #Predicate { $0.path == oldPath || $0.path.starts(with: prefix) }
        ))) ?? []
        for f in favs {
            guard let target = remapped(f.path) else { continue }
            if let clash = favorite(for: target) { context.delete(clash) }
            f.path = target
        }

        for scan in scans() {
            let roots = scan.roots.map { remapped($0) ?? $0 }
            if roots != scan.roots { scan.roots = roots }
            if let canonical = scan.canonicalPath, let target = remapped(canonical) {
                scan.canonicalPath = target
            }
        }
        for bundle in bundles() {
            let paths = bundle.paths.map { remapped($0) ?? $0 }
            if paths != bundle.paths { bundle.paths = paths }
        }

        save("repointPath")
    }
```

(`#Predicate` uses `starts(with:)` — the SwiftData-supported spelling; `hasPrefix` is not translatable.)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Library/LibraryStore.swift Tests/LumeKitTests/LibraryStoreRepointTests.swift Lume.xcodeproj
git commit -m "feat: repointPath keeps library rows attached across renames/moves

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 16: Corrupt-store recovery + visible degraded modes (+ second-window guard)

**Files:**
- Create: `Sources/LumeKit/Library/LibraryContainerFactory.swift`
- Modify: `Sources/Lume/LumeApp.swift` (full file)
- Modify: `Sources/Lume/AppState.swift` (`attach`)
- Test: `Tests/LumeKitTests/LibraryContainerFactoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/LibraryContainerFactoryTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import LumeKit

@MainActor
private func tempStoreDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lume-factory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor @Test func freshStoreOpensHealthy() throws {
    let dir = try tempStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = LibraryContainerFactory.make(at: dir.appendingPathComponent("library.store"))
    defer { withExtendedLifetime(result.container) {} }
    #expect(result.health == .healthy)

    let store = LibraryStore(context: result.container.mainContext)
    store.createEmptyTag(named: "t")
    #expect(store.allTags().map(\.name) == ["t"])
    #expect(store.lastPersistenceError == nil)
}

@MainActor @Test func corruptStoreIsMovedAsideAndReplaced() throws {
    let dir = try tempStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let storeURL = dir.appendingPathComponent("library.store")
    let garbage = Data("definitely not a sqlite database".utf8)
    try garbage.write(to: storeURL)

    let result = LibraryContainerFactory.make(at: storeURL)
    defer { withExtendedLifetime(result.container) {} }

    guard case .recoveredFromCorruption(let backupURL) = result.health else {
        Issue.record("expected .recoveredFromCorruption, got \(result.health)")
        return
    }
    // The corrupt bytes were preserved, not destroyed.
    let backup = try #require(backupURL)
    #expect(try Data(contentsOf: backup) == garbage)
    #expect(backup.lastPathComponent.contains("corrupt-"))

    // The replacement container actually persists.
    let store = LibraryStore(context: result.container.mainContext)
    store.createEmptyTag(named: "fresh")
    #expect(store.allTags().map(\.name) == ["fresh"])
    #expect(store.lastPersistenceError == nil)
}
```

- [ ] **Step 2: Run — expect FAIL** (`LibraryContainerFactory` not defined)

- [ ] **Step 3: Implement the factory**

Create `Sources/LumeKit/Library/LibraryContainerFactory.swift`:

```swift
import Foundation
import SwiftData
import os

/// How persistent-store setup went at launch. Anything but `.healthy` must be
/// surfaced by the app layer — the user's library is degraded.
public enum StoreHealth: Equatable, Sendable {
    /// The persistent store opened (or was freshly created) normally.
    case healthy
    /// The existing store couldn't be opened; it was moved aside to `backupURL`
    /// (nil if the move itself failed) and a fresh persistent store was created.
    /// Favorites/tags/notes start empty but WILL persist from now on.
    case recoveredFromCorruption(backupURL: URL?)
    /// No persistent store could be created at all. The library is in-memory:
    /// nothing will persist across launches.
    case ephemeral
}

/// Creates the app's `ModelContainer` with corrupt-store recovery (audit A3):
/// open normally → on failure move the store aside (timestamped, preserving the
/// user's data for recovery) and retry fresh → only then fall back to in-memory,
/// always reporting what happened. Never `try!`, never silent.
public enum LibraryContainerFactory {
    private static let logger = Logger(subsystem: "com.lume.LumeKit", category: "LibraryContainerFactory")

    /// `storeURL` overrides the default Application Support location (tests).
    public static func make(at storeURL: URL? = nil) -> (container: ModelContainer, health: StoreHealth) {
        let schema = Schema(versionedSchema: LumeSchemaV1.self)
        let config: ModelConfiguration = if let storeURL {
            ModelConfiguration(schema: schema, url: storeURL)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        // 1) Normal path.
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: LumeMigrationPlan.self, configurations: [config]
            )
            return (container, .healthy)
        } catch {
            logger.error("persistent store failed to open: \(error.localizedDescription, privacy: .public)")
        }

        // 2) Move the unreadable store aside and retry with a fresh one.
        let backupURL = moveStoreAside(config.url)
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: LumeMigrationPlan.self, configurations: [config]
            )
            return (container, .recoveredFromCorruption(backupURL: backupURL))
        } catch {
            logger.error("fresh persistent store also failed: \(error.localizedDescription, privacy: .public)")
        }

        // 3) Last resort: in-memory, visibly ephemeral.
        do {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: schema, migrationPlan: LumeMigrationPlan.self, configurations: [memory]
            )
            return (container, .ephemeral)
        } catch {
            // In-memory creation can only fail on a schema programming error,
            // and the app cannot run without a container — crash with a real
            // message instead of the old anonymous `try!`.
            fatalError("Lume could not create even an in-memory model container: \(error)")
        }
    }

    /// Rename `…/default.store` (+ SQLite `-shm`/`-wal` sidecars) to timestamped
    /// `.corrupt-…` siblings so the user's data survives for inspection or
    /// recovery. Returns the main store file's new URL, or nil if nothing moved.
    private static func moveStoreAside(_ storeURL: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let destination = storeURL.appendingPathExtension("corrupt-\(formatter.string(from: .now))")
        do {
            try fm.moveItem(at: storeURL, to: destination)
        } catch {
            logger.error("couldn't move corrupt store aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Sidecars are best-effort: a stale -wal left beside a FRESH store is
        // exactly the corruption vector we're closing, so move them too.
        for ext in ["-shm", "-wal"] {
            try? fm.moveItem(
                at: URL(fileURLWithPath: storeURL.path + ext),
                to: URL(fileURLWithPath: destination.path + ext)
            )
        }
        return destination
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Rewrite LumeApp (factory + second-window guard, AUDIT "second window nukes state")**

Replace `Sources/Lume/LumeApp.swift` entirely:

```swift
import SwiftUI
import AppKit
import SwiftData
import LumeKit

@main
struct LumeApp: App {
    @State private var app = AppState()
    private let container: ModelContainer
    /// How store setup went; handed to AppState so degraded modes get a banner.
    private let storeHealth: StoreHealth

    init() {
        let result = LibraryContainerFactory.make()
        container = result.container
        storeHealth = result.health
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .modelContainer(container)
                .frame(minWidth: 720, minHeight: 440)
                .task {
                    // AppState is shared across windows: only the FIRST window may
                    // run launch setup, or ⌘N would re-attach the library and
                    // re-restore the last folder, nuking the existing window's
                    // navigation/selection state.
                    guard app.library == nil else { return }
                    app.attach(library: LibraryStore(context: container.mainContext),
                               storeHealth: storeHealth)
                    if !app.applyLaunchEnvironment() { app.restoreLastFolder() }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands { LumeCommands(app: app) }
    }
}
```

- [ ] **Step 6: Extend `AppState.attach`**

In `Sources/Lume/AppState.swift`, change `func attach(library: LibraryStore)` (currently ~`:188`) to accept and surface store health. The default keeps any existing callers compiling:

```swift
    func attach(library: LibraryStore, storeHealth: StoreHealth = .healthy) {
        self.library = library
        library.migrateBookmarksToFavorites()
        refreshLibrary()
        switch storeHealth {
        case .healthy:
            break
        case .recoveredFromCorruption(let backupURL):
            let suffix = backupURL.map { " Old data saved at \($0.lastPathComponent)." } ?? ""
            showNotice("Your library couldn't be read and was reset.\(suffix)", duration: .seconds(15))
        case .ephemeral:
            showNotice("Your library is running in-memory: favorites and tags won't persist.", duration: .seconds(15))
        }
    }
```

(Keep whatever else the current `attach` body does — add the `switch` after it; the lines shown before the switch reflect the existing body, verify when editing.)

- [ ] **Step 7: Run full suite + build — expect PASS. Manual: launch normally (no banner); ⌘N a second window — the first window keeps its breadcrumb, selection, and open document.**

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeKit/Library/LibraryContainerFactory.swift Sources/Lume/LumeApp.swift Sources/Lume/AppState.swift Tests/LumeKitTests/LibraryContainerFactoryTests.swift Lume.xcodeproj
git commit -m "fix: corrupt-store recovery with visible degraded modes; guard second-window relaunch (AUDIT A3)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 4 — File operations (rename validation, trash state, async save, overwrite off-main, watcher load)

### Task 17: Rename — validate input, repoint library rows, notice channel

**Files:**
- Modify: `Sources/Lume/AppState.swift:843-856` (`rename`)

- [ ] **Step 1: Implement**

Replace `rename(_:to:)` (currently `:843-856`):

```swift
    /// Rename a file/folder on disk (not its display label).
    func rename(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
        // A rename must stay a single path component: "../evil" or "a/b" would
        // silently relocate the file instead of renaming it.
        guard FileNameValidator.isValid(trimmed) else {
            showNotice("\"\(trimmed)\" isn't a valid file name.")
            return
        }
        let dst = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try fm.moveItem(at: url, to: dst)
            // Keep path-keyed library rows (tags / notes / pins / hidden flag)
            // attached to the renamed file (Task 15's repointPath).
            library?.repointPath(from: url.path, to: dst.path)
            refreshLibrary()
            cache.invalidate(path: url.deletingLastPathComponent().path)
            if selectedURL == url { choose(dst) }
            registerUndo("Rename") { [weak self] in self?.rename(dst, to: url.lastPathComponent) }
        } catch {
            showNotice("Couldn't rename \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
```

(Undo re-invokes `rename`, so the metadata repoints back for free. The original `lastPathComponent` always passes the validator. `duplicate` needs no repoint — a copy correctly starts with fresh rows.)

- [ ] **Step 2: Build + tests — expect PASS**

- [ ] **Step 3: Manual verification**

⌘R a file, type `../escaped.md` → a banner appears and the file does not move out of its directory. Rename a tagged/favorited file normally → its tags, notes, and pin survive; ⌘Z restores both name and metadata.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "fix: validate rename input and repoint library rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 18: Trash — fully reset open-document state

Decision (two audit-fix drafts disagreed): library rows are **left at the original path** when trashing — a restore returns the file to that exact path, so tags/notes/pins survive the round-trip with zero DB churn. Stale rows for never-restored files are the pre-existing condition and out of scope.

**Files:**
- Modify: `Sources/Lume/AppState.swift:870-893` (`moveToTrash` + new `closeDocument`)

- [ ] **Step 1: Implement**

Replace `moveToTrash(_:)` (currently `:870-893`) and add `closeDocument()`:

```swift
    /// Move files to the Trash, undoably (restores them from the Trash).
    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var restores: [(trashed: URL, original: URL)] = []
        for u in urls {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &resulting)
                if let r = resulting as URL? { restores.append((r, u)) }
                cache.invalidate(path: u.deletingLastPathComponent().path)
                if selectedURL == u { closeDocument() }
            } catch {
                showNotice("Couldn't trash \(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        clearSelection()
        registerUndo("Move to Trash") { [weak self] in
            guard let self else { return }
            for (trashed, original) in restores {
                try? self.fm.moveItem(at: trashed, to: original)
                self.cache.invalidate(path: original.deletingLastPathComponent().path)
            }
        }
    }

    /// Reset every piece of open-document state. Clearing only `selectedURL` /
    /// `documentText` leaves `loadedText`/`isDirty`/`selectedKind` stale: Save
    /// stays enabled after the open document is trashed and silently no-ops.
    private func closeDocument() {
        selectedURL = nil
        documentText = nil
        loadedText = nil
        isDirty = false
        selectedKind = .unsupported
    }
```

- [ ] **Step 2: Build + tests — expect PASS**

- [ ] **Step 3: Manual verification**

Open a text file, type a character (dirty), ⌘⌫ to trash it. Verify: File ▸ Save is disabled, the detail pane shows "No File Selected", and selecting an image afterwards does not show the old editor. ⌘Z restores the file with tags/notes intact.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "fix: reset full document state when trashing the open file

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 19: `save()` — coordinated write off the main actor

**Files:**
- Modify: `Sources/Lume/AppState.swift:1268-1279` (`save`)

- [ ] **Step 1: Implement**

Replace `save()`:

```swift
    /// Save the open document back to disk. The coordinated write runs off the
    /// main actor (mirroring `TextDocument.load`) — an iCloud / slow-volume file
    /// can block a coordinated write arbitrarily long.
    func save() {
        guard let url = selectedURL, let text = documentText, isDirty else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TextDocument(url: url, text: text).save()
                }.value
                // Apply dirty tracking only if the same document is still open;
                // if the user kept typing while the write was in flight, the doc
                // stays dirty relative to what actually hit the disk.
                if selectedURL == url {
                    loadedText = text
                    isDirty = (documentText != text)
                }
                cache.invalidate(path: url.deletingLastPathComponent().path)
            } catch {
                showNotice("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
```

(`TextDocument` is `Sendable`. A double ⌘S spawns two identical atomic coordinated writes — harmless. `Task {}` inherits the main actor, so all state mutation stays on main.)

- [ ] **Step 2: Build + tests — expect PASS**

- [ ] **Step 3: Manual verification**

(1) Edit + ⌘S a normal file: Save disables, content on disk. (2) Type immediately after ⌘S: Save stays enabled and a second ⌘S persists the new keystrokes. (3) Make a file unwritable (`chmod 444`), ⌘S → banner with the save error; the editor and unsaved text remain visible.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "fix: run coordinated document saves off the main actor

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 20: Overwrite-with-canonical — extract to LumeKit, run off-main

**Files:**
- Create: `Sources/LumeKit/Document/CanonicalOverwrite.swift`
- Modify: `Sources/Lume/AppState.swift:1096-1134` (`overwrite`)
- Test: `Tests/LumeKitTests/CanonicalOverwriteTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/CanonicalOverwriteTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeKit

struct CanonicalOverwriteTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-overwrite-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func tempBinaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-overwrite-\(UUID().uuidString).bin")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)   // invalid UTF-8
        return url
    }

    @Test func overwritesTargetsAndCapturesRestores() throws {
        let canonical = try tempFile("canon")
        let target = try tempFile("old")
        defer {
            try? FileManager.default.removeItem(at: canonical)
            try? FileManager.default.removeItem(at: target)
        }
        let outcome = try #require(CanonicalOverwrite.run(targets: [target], canonical: canonical))
        #expect(try String(contentsOf: target, encoding: .utf8) == "canon")
        #expect(outcome.restores == [CanonicalOverwrite.Restore(url: target, text: "old")])
        #expect(outcome.skipped.isEmpty)
    }

    @Test func neverWritesTheCanonicalItself() throws {
        let canonical = try tempFile("canon")
        defer { try? FileManager.default.removeItem(at: canonical) }
        let outcome = try #require(CanonicalOverwrite.run(targets: [canonical], canonical: canonical))
        #expect(outcome.restores.isEmpty)
        #expect(outcome.skipped.isEmpty)
    }

    @Test func skipsNonUTF8TargetsUntouched() throws {
        let canonical = try tempFile("canon")
        let binary = try tempBinaryFile()
        defer {
            try? FileManager.default.removeItem(at: canonical)
            try? FileManager.default.removeItem(at: binary)
        }
        let outcome = try #require(CanonicalOverwrite.run(targets: [binary], canonical: canonical))
        #expect(outcome.restores.isEmpty)
        #expect(outcome.skipped == [binary.lastPathComponent])
        #expect(try Data(contentsOf: binary) == Data([0xFF, 0xFE, 0x00, 0x80]))
    }

    @Test func unreadableCanonicalReturnsNilAndWritesNothing() throws {
        let missing = URL(fileURLWithPath: "/nope/missing-\(UUID().uuidString).txt")
        let target = try tempFile("old")
        defer { try? FileManager.default.removeItem(at: target) }
        #expect(CanonicalOverwrite.run(targets: [target], canonical: missing) == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`CanonicalOverwrite` not defined)

- [ ] **Step 3: Implement the LumeKit type**

Create `Sources/LumeKit/Document/CanonicalOverwrite.swift`:

```swift
import Foundation

/// Overwrites scan-result files with a canonical file's text. Pure file-level
/// logic (no app state) so the destructive path is unit-testable and can run
/// off the main actor; the caller applies the returned outcome (undo
/// registration, cache invalidation, error reporting) back on main.
public enum CanonicalOverwrite {

    /// One reversible write: the file overwritten and its previous text.
    public struct Restore: Equatable, Sendable {
        public let url: URL
        public let text: String
        public init(url: URL, text: String) {
            self.url = url
            self.text = text
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let restores: [Restore]
        public let skipped: [String]
        public init(restores: [Restore], skipped: [String]) {
            self.restores = restores
            self.skipped = skipped
        }
    }

    /// Overwrite each target with `canonical`'s text. Returns nil when the
    /// canonical file itself can't be read as UTF-8.
    public static func run(targets: [URL], canonical: URL) -> Outcome? {
        guard let canonText = try? String(contentsOf: canonical, encoding: .utf8) else {
            return nil
        }
        var restores: [Restore] = []
        var skipped: [String] = []
        for target in targets where target.path != canonical.path {
            // Only overwrite files we can read back as UTF-8 text. A binary or
            // non-UTF-8 target has no faithful undo (we'd capture "" and restore an
            // empty file), so skip it entirely rather than risk destroying data.
            guard let old = try? String(contentsOf: target, encoding: .utf8) else {
                skipped.append(target.lastPathComponent)
                continue
            }
            do {
                try TextDocument(url: target, text: canonText).save()
                restores.append(Restore(url: target, text: old))
            } catch {
                skipped.append(target.lastPathComponent)
            }
        }
        return Outcome(restores: restores, skipped: skipped)
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Rewire AppState**

Replace `overwrite(_:withCanonical:)` (currently `:1096-1134`):

```swift
    /// Overwrite each target with the canonical file's text; registers a single
    /// undo. The file I/O runs off the main actor (an "Overwrite all differing
    /// (N)" over many files would otherwise beachball the UI); the outcome —
    /// undo registration, cache invalidation, report banner — applies on main.
    private func overwrite(_ targets: [URL], withCanonical canonical: URL) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                CanonicalOverwrite.run(targets: targets, canonical: canonical)
            }.value
            guard let outcome else {
                showNotice("Couldn't read the canonical file.")
                return
            }
            for restore in outcome.restores {
                cache.invalidate(path: restore.url.deletingLastPathComponent().path)
            }
            if !outcome.restores.isEmpty {
                let restores = outcome.restores
                registerUndo("Overwrite with Canonical") { [weak self] in
                    for restore in restores {
                        try? TextDocument(url: restore.url, text: restore.text).save()
                        self?.cache.invalidate(path: restore.url.deletingLastPathComponent().path)
                    }
                    Task { await self?.recomputeSyncStatus() }
                }
            }
            if !outcome.skipped.isEmpty {
                let n = outcome.restores.count
                showNotice("Overwrote \(n) file\(n == 1 ? "" : "s"); skipped \(outcome.skipped.count) not readable as text: \(outcome.skipped.joined(separator: ", "))")
            }
            await recomputeSyncStatus()
        }
    }
```

(This also fixes the audit's headline error-channel case: a partial *success* no longer replaces the document with a full-pane "error".)

- [ ] **Step 6: Build + full suite — expect PASS**

- [ ] **Step 7: Manual verification**

"Overwrite all differing (N)" over a scan including one binary target: UI stays responsive, a banner reports "Overwrote N; skipped 1…" over the visible triage pane, ⌘Z restores all overwritten files.

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeKit/Document/CanonicalOverwrite.swift Sources/Lume/AppState.swift Tests/LumeKitTests/CanonicalOverwriteTests.swift Lume.xcodeproj
git commit -m "fix: run canonical overwrite off-main via testable LumeKit core

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 21: Watcher callback — stat off-main, skip library refresh for untracked churn

**Files:**
- Create: `Sources/LumeKit/Library/LibraryChangeFilter.swift`
- Modify: `Sources/Lume/AppState.swift:258-275` (`startWatching`), `:816-820` (`isRegularFile`)
- Test: `Tests/LumeKitTests/LibraryChangeFilterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/LibraryChangeFilterTests.swift`:

```swift
import Testing
@testable import LumeKit

@Test func untrackedChurnDoesNotAffectLibrary() {
    #expect(!LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/src/main.swift", "/repo/src"],
        favoritePaths: ["/repo/CLAUDE.md"],
        hiddenPaths: ["/repo/secret.md"],
        groupFilePaths: ["docs": ["/repo/README.md"]]
    ))
}

@Test func favoriteChangeAffectsLibrary() {
    #expect(LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/CLAUDE.md"],
        favoritePaths: ["/repo/CLAUDE.md"],
        hiddenPaths: [],
        groupFilePaths: [:]
    ))
}

@Test func hiddenPathChangeAffectsLibrary() {
    #expect(LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/secret.md"],
        favoritePaths: [],
        hiddenPaths: ["/repo/secret.md"],
        groupFilePaths: [:]
    ))
}

@Test func groupMemberChangeAffectsLibrary() {
    #expect(LibraryChangeFilter.affectsLibrary(
        changed: ["/repo/README.md"],
        favoritePaths: [],
        hiddenPaths: [],
        groupFilePaths: ["docs": ["/repo/README.md"], "empty": []]
    ))
}

@Test func emptyChangeSetIsFalse() {
    #expect(!LibraryChangeFilter.affectsLibrary(
        changed: [],
        favoritePaths: ["/a"],
        hiddenPaths: ["/b"],
        groupFilePaths: ["g": ["/c"]]
    ))
}
```

- [ ] **Step 2: Run — expect FAIL** (`LibraryChangeFilter` not defined)

- [ ] **Step 3: Implement the filter**

Create `Sources/LumeKit/Library/LibraryChangeFilter.swift`:

```swift
import Foundation

/// Decides whether a batch of changed file paths can affect the library's
/// cached projections (favorites / group members / hidden flags). FSEvents
/// churn under untracked paths (e.g. a `git checkout`) only needs the
/// enumeration-cache invalidation, not a full SwiftData re-read.
public enum LibraryChangeFilter {
    public static func affectsLibrary(
        changed: Set<String>,
        favoritePaths: [String],
        hiddenPaths: Set<String>,
        groupFilePaths: [String: [String]]
    ) -> Bool {
        guard !changed.isEmpty else { return false }
        if favoritePaths.contains(where: changed.contains) { return true }
        if !hiddenPaths.isDisjoint(with: changed) { return true }
        for members in groupFilePaths.values where members.contains(where: changed.contains) {
            return true
        }
        return false
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Rewire AppState**

Replace `startWatching(_:)` (currently `:258-275`):

```swift
    /// Watch the open tree; an external change invalidates the affected
    /// directories (so the browser re-reads just those) and refreshes the library.
    private func startWatching(_ root: URL) {
        watcher?.stop()
        watcher = DirectoryWatcher(root: root) { [weak self] changed in
            guard let self else { return }
            for path in changed { self.cache.invalidate(path: path) }
            self.recordActivity(for: changed)
            // Re-read the SwiftData projections only when a changed path is one
            // the library actually tracks; for untracked churn (e.g. a `git
            // checkout` under the root) the invalidation above is enough —
            // browser rows already re-read via `cache.revision`.
            let affectsLibrary = LibraryChangeFilter.affectsLibrary(
                changed: changed,
                favoritePaths: self.favorites.map(\.path),
                hiddenPaths: self.hiddenPaths,
                groupFilePaths: self.groupFilePaths
            )
            if affectsLibrary { self.refreshLibrary() }
        }
    }

    /// Record changed regular files into the activity log. The per-path `stat`
    /// runs off the main actor so a large burst can't stall the UI.
    private func recordActivity(for changed: Set<String>) {
        let candidates = changed.filter { !ActivityLog.isIgnored($0) }
        guard !candidates.isEmpty else { return }
        let stamp = Date()
        Task { [weak self] in
            // Sort for deterministic within-burst order (Set iteration is unordered;
            // entries share a timestamp so the order is cosmetic but should be stable).
            let recordable = await Task.detached(priority: .utility) {
                candidates.filter { Self.isRegularFile($0) }.sorted()
            }.value
            guard let self, !recordable.isEmpty else { return }
            var log = self.activity
            log.record(recordable, at: stamp)
            self.activity = log
        }
    }
```

Replace `isRegularFile` (currently `:816-820`) with the `nonisolated static` form so the detached closure can call it:

```swift
    /// True if `path` is an existing regular file (not a directory).
    private nonisolated static func isRegularFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
```

(`isRegularFile` has no other callers — verified. LibraryStore exposes no incremental fetch APIs, so skip-when-untracked is the available lever; FSEvents' 0.25s latency already coalesces bursts.)

- [ ] **Step 6: Build + full suite — expect PASS**

- [ ] **Step 7: Manual verification**

Open a large git repo in Lume, run `git checkout <other-branch>` in Terminal: the sidebar stays responsive (no multi-second beachball) and reflects the new tree. Touch a favorited/tagged file externally: library-driven rows still refresh.

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeKit/Library/LibraryChangeFilter.swift Sources/Lume/AppState.swift Tests/LumeKitTests/LibraryChangeFilterTests.swift Lume.xcodeproj
git commit -m "perf: keep FSEvents bursts off the main thread; skip untracked library refreshes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 5 — Security (AUDIT C5, C6, S-findings)

### Task 22: Harden HTMLViewer — no JS, navigation locked to the file's directory

Trade-off, made deliberately: read access stays scoped to the file's parent **directory** (not just the file) so relative images/stylesheets keep rendering — that's what makes local HTML preview useful. With scripts off and navigation locked, a malicious page can *display* sibling files it already references but cannot execute code or send anything anywhere.

**Files:**
- Modify: `Sources/Lume/Viewers/HTMLViewer.swift` (full file)

- [ ] **Step 1: Implement**

Replace the file:

```swift
import SwiftUI
import WebKit

/// Plain WKWebView for local HTML content — hardened for untrusted files:
/// content JavaScript is disabled and navigation is restricted to file:// URLs
/// inside the loaded file's own directory (remote navigation is denied).
struct HTMLViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Content-only viewing: never execute scripts from arbitrary local files.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            load(url, in: webView, coordinator: context.coordinator)
        }
    }

    private func load(_ url: URL, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        coordinator.allowedDirectory = url.deletingLastPathComponent().standardizedFileURL
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var allowedDirectory: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            allows(navigationAction.request.url) ? .allow : .cancel
        }

        /// Only file:// URLs inside the loaded file's directory may navigate
        /// (covers the initial load, in-page anchors, and links to siblings).
        /// http(s), custom schemes, and `../` traversal out of the directory
        /// are all denied.
        private func allows(_ target: URL?) -> Bool {
            guard let target, target.isFileURL, let allowedDirectory else { return false }
            let targetPath = target.standardizedFileURL.path
            let dirPath = allowedDirectory.path
            return targetPath == dirPath || targetPath.hasPrefix(dirPath + "/")
        }
    }
}
```

- [ ] **Step 2: Build + manual verification**

Create `/tmp/lume-html/evil.html`: `<h1 id="t">static</h1><img src="pic.png"><link rel="stylesheet" href="style.css"><script>document.getElementById('t').textContent='JS RAN'; location.href='https://example.com';</script><a href="https://example.com">remote</a><a href="sibling.html">sibling</a><a href="../../../etc/hosts">traversal</a>` plus `style.css` (`h1{color:red}`), any `pic.png`, and a `sibling.html`. Open the folder in Lume, select `evil.html`. Expect: heading says "static" (JS off), image renders, heading is red (relative CSS works), no redirect. "remote" and "traversal" links do nothing; "sibling" renders.

- [ ] **Step 3: Commit**

```bash
git add Sources/Lume/Viewers/HTMLViewer.swift
git commit -m "fix: disable JS and lock navigation in HTMLViewer (AUDIT C5)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 23: DirectoryWatcher — close the teardown use-after-free window

**Files:**
- Modify: `Sources/LumeKit/FileSystem/DirectoryWatcher.swift` (full file)
- Test: append to `Tests/LumeKitTests/FileSystemCacheTests.swift`

- [ ] **Step 1: Write the new tests** (these also close the audit's "watcherInitAndStopSmoke asserts nothing" gap; the smoke test stays)

Append to `FileSystemCacheTests.swift`:

```swift
/// Collects watcher deliveries on the main actor.
@MainActor
private final class ChangeCollector {
    var paths: Set<String> = []
}

@MainActor
@Test func watcherDeliversChangeForFileWrite() async throws {
    let dir = try makeTempDirWithFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = ChangeCollector()
    let watcher = DirectoryWatcher(root: dir) { collector.paths.formUnion($0) }
    defer { watcher.stop() }

    // Give FSEvents a beat to arm, then write; stream latency is 0.25s, so poll.
    try await Task.sleep(for: .milliseconds(300))
    try "y".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    for _ in 0..<100 where collector.paths.isEmpty {
        try await Task.sleep(for: .milliseconds(100))
    }
    // FSEvents reports /private-prefixed temp paths; compare by suffix.
    #expect(collector.paths.contains { $0.hasSuffix(dir.lastPathComponent) })
}

@MainActor
@Test func droppingWatcherWithEventsInFlightDoesNotCrash() async throws {
    // Regression for the teardown use-after-free window: generate events and
    // immediately stop + drop the last reference, exactly like
    // AppState.startWatching does when switching roots. Under the old
    // passUnretained context this could resurrect a deallocated watcher.
    for _ in 0..<20 {
        let dir = try makeTempDirWithFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        var watcher: DirectoryWatcher? = DirectoryWatcher(root: dir) { _ in }
        for i in 0..<5 {
            try "x".write(to: dir.appendingPathComponent("f\(i).md"),
                          atomically: true, encoding: .utf8)
        }
        watcher?.stop()
        watcher = nil
    }
    // Let any retained sinks and queued releases settle; passes by not crashing.
    try await Task.sleep(for: .milliseconds(500))
}
```

(If `makeTempDirWithFile()` is named differently in this file, use the existing temp-dir helper; check the file's current helpers when editing.)

- [ ] **Step 2: Implement — replace `Sources/LumeKit/FileSystem/DirectoryWatcher.swift` entirely**

```swift
import Foundation
import CoreServices

/// Watches a directory subtree for filesystem changes via FSEvents and delivers
/// the set of changed directory paths to a `@MainActor` closure. Used to keep
/// the cached file tree in sync with external edits (Finder, other apps) without
/// polling.
///
/// Concurrency & lifetime: FSEvents calls back on a private serial dispatch
/// queue. The stream's context `info` is an `EventSink` that FSEvents itself
/// retains (the context supplies retain/release callbacks), so the callback
/// target stays alive until the stream is fully invalidated — an in-flight
/// event can never observe a deallocated object, even when the last
/// `DirectoryWatcher` reference is dropped immediately after `stop()`.
/// `teardown()` additionally drains the callback queue synchronously, so once
/// `stop()` returns no callback is still executing.
public final class DirectoryWatcher {

    /// The object FSEvents retains as its context `info`. Holds only the
    /// immutable change handler; events are delivered by hopping to the main
    /// actor. `@unchecked Sendable`: the single stored property is a `let`
    /// main-actor closure that is only ever *invoked* on the main actor.
    private final class EventSink: @unchecked Sendable {
        private let onChange: @MainActor (Set<String>) -> Void

        init(onChange: @escaping @MainActor (Set<String>) -> Void) {
            self.onChange = onChange
        }

        /// Hop the changed-path set to the main actor and invoke `onChange`.
        func deliver(_ dirs: Set<String>) {
            guard !dirs.isEmpty else { return }
            let handler = onChange
            Task { @MainActor in handler(dirs) }
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.lume.DirectoryWatcher", qos: .utility)

    /// Start watching `root` (recursively). `onChange` receives the set of
    /// changed directory paths on the main actor.
    public init(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
        start(root: root, sink: EventSink(onChange: onChange))
    }

    deinit {
        // `teardown()` is safe to call off the main actor: it only touches the
        // FSEvents stream handle and the private queue, never the sink.
        teardown()
    }

    private func start(root: URL, sink: EventSink) {
        // passUnretained + retain/release callbacks: FSEventStreamCreate copies
        // the context and takes its OWN +1 on the sink via `retain`, balanced
        // by `release` after the stream is invalidated and its pending queue
        // work has completed. The sink's lifetime is therefore owned by
        // FSEvents, not by this watcher, which closes the use-after-free
        // window on teardown.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventSink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a
            // CFArray of CFString.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var dirs: Set<String> = []
            for i in 0..<count {
                if let cfPath = CFArrayGetValueAtIndex(cfArray, i) {
                    let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
                    // File-level events report the file path; the tree caches by
                    // DIRECTORY, so collapse to the containing directory.
                    dirs.insert((path as NSString).deletingLastPathComponent)
                    dirs.insert(path)
                }
            }
            sink.deliver(dirs)
        }

        let pathsToWatch = [root.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, // latency (seconds): coalesce bursts
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stop watching and release the FSEvents stream. Idempotent.
    public func stop() {
        teardown()
    }

    private func teardown() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Drain the callback queue: any event callback that was already
        // executing has finished by the time this returns. This can never
        // deadlock — nothing in this class runs `teardown()` ON `queue`
        // (the sink never references the watcher, so even the final release
        // of `self` cannot occur there).
        queue.sync {}
    }
}
```

**IMPORTANT:** Before replacing, diff the current file — if the existing callback body differs from the inline `callback` above (e.g. different dir-collapsing logic), preserve the existing event-processing semantics and change only the lifetime mechanics (`EventSink`, retain/release context, queue drain). Public API (`init(root:onChange:)`, `stop()`) is unchanged, so `AppState.startWatching` needs no edits.

- [ ] **Step 3: Run full suite — expect PASS** (the new delivery + teardown tests included)

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeKit/FileSystem/DirectoryWatcher.swift Tests/LumeKitTests/FileSystemCacheTests.swift
git commit -m "fix: retain FSEvents sink and drain queue on teardown (AUDIT C6)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 24: FileService — stop following symlinks into directories

**Files:**
- Modify: `Sources/LumeKit/FileNode.swift` (full file)
- Modify: `Sources/LumeKit/FileSystem/FileService.swift:28-48` (`enumerate`)
- Test: `Tests/LumeKitTests/FileServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/FileServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeKit

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumeFileServiceTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func symlinkedDirectoryIsListedAsLeafNotDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try "x".write(to: target.appendingPathComponent("inner.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent("link"), withDestinationURL: target)

    let nodes = try FileService().enumerate(dir, includeHidden: false)

    let link = try #require(nodes.first { $0.name == "link" })
    #expect(link.isSymlink)
    // Leaf row: the sidebar only enumerates nodes with isDirectory == true,
    // so the link's target can never be expanded in the browser.
    #expect(!link.isDirectory)

    let real = try #require(nodes.first { $0.name == "real" })
    #expect(real.isDirectory)
    #expect(!real.isSymlink)
}

@Test func symlinkedFileIsStillListedAndMarked() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.md")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent("alias.md"), withDestinationURL: file)

    let nodes = try FileService().enumerate(dir, includeHidden: false)
    #expect(nodes.map(\.name).contains("alias.md"))
    let alias = try #require(nodes.first { $0.name == "alias.md" })
    #expect(alias.isSymlink)
    #expect(!alias.isDirectory)
}

@Test func regularNodesAreNotMarkedSymlink() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "x".write(to: dir.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)

    let nodes = try FileService().enumerate(dir, includeHidden: false)
    #expect(nodes.allSatisfy { !$0.isSymlink })
}
```

- [ ] **Step 2: Run — expect FAIL** (`isSymlink` not defined)

- [ ] **Step 3: Implement**

Replace `Sources/LumeKit/FileNode.swift`:

```swift
import Foundation

/// A node in the file tree. `children == nil` means "not a directory" or
/// "directory not yet expanded"; the sidebar loads children lazily.
public struct FileNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// True for symbolic links. Symlinks are listed as LEAF rows and never
    /// enumerated into — the target may point outside the opened tree
    /// (e.g. a link to ~/.ssh must not expose its contents in the browser).
    public let isSymlink: Bool
    public var children: [FileNode]?
    public var id: URL { url }

    public init(url: URL, isDirectory: Bool, isSymlink: Bool = false, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.children = children
    }

    public var name: String { url.lastPathComponent }
    public var kind: FileKind { FileKind.detect(filename: name) }
}
```

Replace `FileService.enumerate` (currently `:28-48`):

```swift
    public func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        )
        let nodes: [FileNode] = entries.compactMap { url in
            let name = url.lastPathComponent
            if Self.ignoredNames.contains(name) { return nil }
            // Hide dotfiles unless "Show hidden" is on. `.env*` stays visible
            // either way (it's a curated config, not noise).
            if !includeHidden, name.hasPrefix("."), name != ".env", !name.hasPrefix(".env.") { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink ?? false
            // Symlinks are listed but NEVER treated as directories (matching
            // ScanEngine's symlink skip): reporting them as leaves means the
            // sidebar can't expand into a target outside the opened tree.
            let isDir = !isSymlink && (values?.isDirectory ?? false)
            return FileNode(url: url, isDirectory: isDir, isSymlink: isSymlink, children: nil)
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory } // folders first
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
```

(The new `isSymlink` parameter is defaulted, and `FileNode(url:isDirectory:children:)` is constructed only here across the whole codebase — no other ripple. Symlinked *files* still open; only tree traversal through links is blocked.)

- [ ] **Step 4: Run full suite — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/FileNode.swift Sources/LumeKit/FileSystem/FileService.swift Tests/LumeKitTests/FileServiceTests.swift Lume.xcodeproj
git commit -m "fix: list symlinks as leaves; never enumerate through them

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 25: `Pasteboard` facade — conceal secret-bearing clipboard writes

**Files:**
- Create: `Sources/Lume/Pasteboard.swift`
- Modify: `Sources/Lume/Viewers/EnvEditorView.swift:63-68`, `Sources/Lume/AppState.swift:822-828`, `:1034-1046`

- [ ] **Step 1: Create the facade**

Create `Sources/Lume/Pasteboard.swift`:

```swift
import AppKit

/// Tiny NSPasteboard facade so every clipboard write goes through one place,
/// and secret-bearing writes are concealed consistently.
enum Pasteboard {
    /// Clipboard-manager opt-out marker (see http://nspasteboard.org): managers
    /// that honor it skip the entry, so secrets aren't persisted in clipboard
    /// history or synced via Universal Clipboard handlers.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Replace the general pasteboard contents with `text`. Pass
    /// `concealed: true` for anything that may contain a secret (env values,
    /// assembled file contents); plain for inert text like file paths.
    static func write(_ text: String, concealed: Bool = false) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            pasteboard.setString("", forType: concealedType)
        }
    }
}
```

- [ ] **Step 2: Migrate call sites**

`EnvEditorView.swift:63-68` — replace the copy button action:

```swift
                Button {
                    Pasteboard.write(entry.value, concealed: true)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy value")
```

`AppState.swift:822-828` — replace `copySelectedPaths`:

```swift
    /// Copy the selected files' POSIX paths to the clipboard (⌥⌘C).
    func copySelectedPaths() {
        Pasteboard.write(PathExport.clipboardString(for: selectedURLs))
    }
```

`AppState.swift:1034-1046` — delete the private `writeToPasteboard(_:)` and replace its three users:

```swift
    func copyTickedPaths() {
        Pasteboard.write(PathExport.clipboardString(for: tickedURLs))
    }

    func copyTickedAsPrompt() {
        Pasteboard.write(PathExport.promptString(for: tickedURLs))
    }
```

and in `performContextCopy` (`:1161-1164`) replace `writeToPasteboard(assembled.text)` with:

```swift
        Pasteboard.write(assembled.text, concealed: true)
```

(Decision: path/prompt copies are routed through the facade for consistency but NOT concealed — they contain no file contents, and concealing them would needlessly break clipboard-history workflows.)

- [ ] **Step 3: Build + manual verification**

Open a `.env` with `API_KEY=abc123`, copy a value, run `osascript -e 'clipboard info'`: output lists the UTF-8 type AND `org.nspasteboard.ConcealedType`; `pbpaste` still prints `abc123`. Copy as Context → ConcealedType present. ⌥⌘C (paths) → ConcealedType absent.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/Pasteboard.swift Sources/Lume/Viewers/EnvEditorView.swift Sources/Lume/AppState.swift Lume.xcodeproj
git commit -m "fix: conceal secret-bearing pasteboard writes from clipboard managers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 26: SecretDetector — broader filename coverage + content scan, wired into Copy as Context

**Files:**
- Modify: `Sources/LumeKit/Document/SecretDetector.swift` (full file)
- Modify: `Sources/Lume/AppState.swift:1136-1164` (Copy as Context block)
- Modify: `Sources/Lume/ContentView.swift` (dialog title)
- Test: `Tests/LumeKitTests/SecretDetectorTests.swift` (full replacement)

- [ ] **Step 1: Replace the test file** (new false-positive guards `secretary.md`/`dotenv.md`/`pemberton.txt` FAIL against the current substring matcher — that's the point)

Replace `Tests/LumeKitTests/SecretDetectorTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeKit

// MARK: - Filename heuristics

@Test func flagsEnvFamily() {
    #expect(SecretDetector.isSensitive(".env"))
    #expect(SecretDetector.isSensitive(".env.local"))
    #expect(SecretDetector.isSensitive(".env.production"))
}

@Test func flagsKeysAndCredentials() {
    #expect(SecretDetector.isSensitive("server.pem"))
    #expect(SecretDetector.isSensitive("id_rsa"))
    #expect(SecretDetector.isSensitive("my-secret.txt"))
    #expect(SecretDetector.isSensitive("aws_credentials"))
}

@Test func flagsKeyMaterialExtensions() {
    #expect(SecretDetector.isSensitive("server.key"))
    #expect(SecretDetector.isSensitive("AuthKey_AB12CD34EF.p8"))
    #expect(SecretDetector.isSensitive("identity.p12"))
    #expect(SecretDetector.isSensitive("cert.pfx"))
    #expect(SecretDetector.isSensitive("release.jks"))
    #expect(SecretDetector.isSensitive("debug.keystore"))
    #expect(SecretDetector.isSensitive("putty.ppk"))
}

@Test func flagsCredentialDotfilesAndServiceAccounts() {
    #expect(SecretDetector.isSensitive(".netrc"))
    #expect(SecretDetector.isSensitive(".npmrc"))
    #expect(SecretDetector.isSensitive(".pgpass"))
    #expect(SecretDetector.isSensitive(".git-credentials"))
    #expect(SecretDetector.isSensitive("service-account.json"))
    #expect(SecretDetector.isSensitive("service-account-prod.json"))
}

@Test func doesNotFlagOrdinaryConfig() {
    #expect(!SecretDetector.isSensitive("CLAUDE.md"))
    #expect(!SecretDetector.isSensitive("config.json"))
    #expect(!SecretDetector.isSensitive("README.md"))
}

@Test func doesNotFlagLookalikeNames() {
    // False-positive guards: substrings of secret-ish words must NOT match.
    #expect(!SecretDetector.isSensitive("secretary.md"))
    #expect(!SecretDetector.isSensitive("dotenv.md"))
    #expect(!SecretDetector.isSensitive("pemberton.txt"))
}

@Test func sensitiveFilesFiltersURLs() {
    let urls = [
        URL(fileURLWithPath: "/p/CLAUDE.md"),
        URL(fileURLWithPath: "/p/.env"),
        URL(fileURLWithPath: "/p/key.pem"),
    ]
    #expect(SecretDetector.sensitiveFiles(in: urls).map(\.lastPathComponent) == [".env", "key.pem"])
}

@Test func flagsMoreSSHKeyTypesAndIsCaseInsensitive() {
    #expect(SecretDetector.isSensitive("id_ed25519"))
    #expect(SecretDetector.isSensitive("id_ecdsa"))
    #expect(SecretDetector.isSensitive(".ENV"))
    #expect(SecretDetector.isSensitive("Server.PEM"))
}

// MARK: - Content heuristics

@Test func contentFlagsAWSAccessKey() {
    let body = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
    #expect(SecretDetector.firstContentMatch(in: body) == .awsAccessKeyID)
    #expect(SecretDetector.containsLikelySecret(body))
}

@Test func contentFlagsPrivateKeyBlocks() {
    #expect(SecretDetector.firstContentMatch(
        in: "-----BEGIN PRIVATE KEY-----\nMIIEv…") == .privateKeyBlock)
    #expect(SecretDetector.firstContentMatch(
        in: "-----BEGIN RSA PRIVATE KEY-----") == .privateKeyBlock)
    #expect(SecretDetector.firstContentMatch(
        in: "-----BEGIN OPENSSH PRIVATE KEY-----") == .privateKeyBlock)
}

@Test func contentFlagsPlatformTokens() {
    #expect(SecretDetector.firstContentMatch(
        in: "token: ghp_16C7e42F292c6912E7710c838347Ae178B4a") == .gitHubToken)
    #expect(SecretDetector.firstContentMatch(
        in: "SLACK=xoxb-test-fixture-not-a-real-token") == .slackToken)
    #expect(SecretDetector.firstContentMatch(
        in: "OPENAI_API_KEY short ref sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz12") == .skAPIKey)
}

@Test func contentFlagsHighEntropyAssignment() {
    let hexValue = "api_key=f3a9c2e84b7d165091a2b3c4d5e6f708"            // 32 hex chars
    let b64Value = "SECRET_TOKEN: dGhpc2lzYXZlcnlsb25nYmFzZTY0c3RyaW5nIQ=="
    #expect(SecretDetector.firstContentMatch(in: hexValue) == .highEntropyAssignment)
    #expect(SecretDetector.firstContentMatch(in: b64Value) == .highEntropyAssignment)
}

@Test func contentDoesNotFlagOrdinaryCodeOrProse() {
    let swiftSource = """
    let tokenEstimate = TokenEstimator.estimate(text)
    let key = "contextFormat"
    // password handling lives elsewhere; see SecretDetector
    """
    let prose = "The secret to good token budgets: keep keys short. key: abc123"
    #expect(!SecretDetector.containsLikelySecret(swiftSource))
    #expect(!SecretDetector.containsLikelySecret(prose))
    #expect(SecretDetector.firstContentMatch(in: "") == nil)
}

@Test func contentScanIsLinearOnAdversarialInput() {
    // Near-miss flood for the assignment rule: must finish instantly (no ReDoS).
    let adversarial = String(repeating: "key= " + String(repeating: "A", count: 31) + "! ", count: 2_000)
    let start = Date()
    _ = SecretDetector.containsLikelySecret(adversarial)
    #expect(Date().timeIntervalSince(start) < 1.0)
}
```

- [ ] **Step 2: Run — expect FAIL** (lookalike guards + content API missing)

- [ ] **Step 3: Implement — replace `Sources/LumeKit/Document/SecretDetector.swift`**

```swift
import Foundation

/// Flags filenames — and, for bulk copies, file CONTENTS — that likely contain
/// secrets, so the UI can warn before they are copied into a chatbot paste.
public enum SecretDetector {

    // MARK: - Filename heuristics

    public static func sensitiveFiles(in urls: [URL]) -> [URL] {
        urls.filter { isSensitive($0.lastPathComponent) }
    }

    public static func isSensitive(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        if exactNames.contains(lower) { return true }
        if keyMaterialExtensions.contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ecdsa")
            || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_dsa") { return true }
        if lower.hasPrefix("service-account"), lower.hasSuffix(".json") { return true }
        if containsWord("secret", in: lower) || containsWord("credential", in: lower) { return true }
        return false
    }

    /// Dotfiles that are credential stores by convention.
    private static let exactNames: Set<String> = [
        ".netrc", ".npmrc", ".pgpass", ".git-credentials",
    ]

    /// Key-material extensions: flagged regardless of base name.
    private static let keyMaterialExtensions: [String] = [
        ".pem", ".key", ".p8", ".p12", ".pfx", ".jks", ".keystore", ".ppk",
    ]

    /// True when `word` occurs in `lower` NOT as a prefix of a longer word —
    /// "client_secret.json" and "aws_credentials" match, "secretary.md"
    /// doesn't. An optional plural "s" is allowed.
    private static func containsWord(_ word: String, in lower: String) -> Bool {
        var search = lower[...]
        while let range = search.range(of: word) {
            var end = range.upperBound
            if end < lower.endIndex, lower[end] == "s" { end = lower.index(after: end) }
            if end == lower.endIndex || !lower[end].isLetter { return true }
            search = lower[range.upperBound...]
        }
        return false
    }

    // MARK: - Content heuristics

    /// Why a piece of content was flagged; `label` drives the warning copy.
    public enum ContentMatch: String, CaseIterable, Sendable {
        case awsAccessKeyID = "an AWS access key ID"
        case privateKeyBlock = "a private key block"
        case gitHubToken = "a GitHub token"
        case slackToken = "a Slack token"
        case skAPIKey = "an sk-… API key"
        case highEntropyAssignment = "a long credential-looking assignment"

        public var label: String { rawValue }
    }

    /// True when `content` contains something shaped like a credential.
    public static func containsLikelySecret(_ content: String) -> Bool {
        firstContentMatch(in: content) != nil
    }

    /// The first content pattern that matches, or nil. Every pattern is a
    /// fixed token shape with single, non-nested quantifiers over disjoint
    /// adjacent character classes — linear-time on adversarial input (no ReDoS).
    public static func firstContentMatch(in content: String) -> ContentMatch? {
        let range = NSRange(content.startIndex..., in: content)
        for (kind, regex) in contentRules
            where regex.firstMatch(in: content, options: [], range: range) != nil {
            return kind
        }
        return nil
    }

    private static let contentRules: [(ContentMatch, NSRegularExpression)] = {
        func re(_ pattern: String,
                _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Patterns are compile-time constants; a typo is a programmer error.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            (.awsAccessKeyID, re("AKIA[0-9A-Z]{16}")),
            (.privateKeyBlock, re("-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----")),
            (.gitHubToken, re("\\bgh[pousr]_[A-Za-z0-9]{20,}")),
            (.slackToken, re("\\bxox[baprs]-[A-Za-z0-9-]{10,}")),
            (.skAPIKey, re("\\bsk-[A-Za-z0-9_-]{24,}")),
            // key/secret/token/password = (or :) a 32+ char base64/hex-ish
            // value. Long enough that prose and ordinary code don't trip it.
            (.highEntropyAssignment,
             re("(?:key|secret|token|password|passwd|pwd)[\"']?[ \\t]{0,8}[:=][ \\t]{0,8}[\"']?[A-Za-z0-9+/=]{32,}",
                [.caseInsensitive])),
        ]
    }()
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Wire the content scan into Copy as Context**

Replace the `// MARK: - Copy as Context` block in `AppState.swift` (currently `:1136-1164`; `copyAsContext` through `performContextCopy`):

```swift
    // MARK: - Copy as Context

    /// Copy the given files' CONTENTS as one LLM-pasteable blob. If any file
    /// LOOKS secret by name, or the assembled text CONTAINS something shaped
    /// like a credential, stage a confirmation instead of copying immediately.
    func copyAsContext(urls: [URL]) {
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        if !SecretDetector.sensitiveFiles(in: unique).isEmpty {
            pendingContextCopy = unique
            return
        }
        // Filenames look clean — scan the assembled contents too, so an AWS
        // key sitting inside an innocuous config.json still warns.
        let assembled = ContextAssembler.assemble(unique, format: contextFormat)
        if SecretDetector.containsLikelySecret(assembled.text) {
            pendingContextCopy = unique
            return
        }
        Pasteboard.write(assembled.text, concealed: true)
    }

    /// Copy the current Scan triage ticked set as context.
    func copyTickedAsContext() { copyAsContext(urls: tickedURLs) }

    func confirmPendingContextCopy() {
        if let urls = pendingContextCopy { performContextCopy(urls) }
        pendingContextCopy = nil
    }

    func cancelPendingContextCopy() { pendingContextCopy = nil }

    /// Assemble and copy without re-scanning (the user already confirmed).
    private func performContextCopy(_ urls: [URL]) {
        let assembled = ContextAssembler.assemble(urls, format: contextFormat)
        Pasteboard.write(assembled.text, concealed: true)
    }
```

In `ContentView.swift`, update the confirmation-dialog title to cover both trigger kinds — replace the string

`"This selection includes secrets (e.g. .env). Copy their contents anyway?"`

with:

`"This selection looks like it includes secrets (a sensitive filename, or credential-shaped content). Copy anyway?"`

- [ ] **Step 6: Build + full suite — expect PASS. Manual: Copy-as-Context a folder containing `config.json` with `api_key=<32 hex chars>` → confirmation dialog appears.**

- [ ] **Step 7: Commit**

```bash
git add Sources/LumeKit/Document/SecretDetector.swift Sources/Lume/AppState.swift Sources/Lume/ContentView.swift Tests/LumeKitTests/SecretDetectorTests.swift
git commit -m "feat: SecretDetector content scan + broader filename coverage, wired into Copy as Context

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 6 — Config-format round-trip fixes (AUDIT C3, C4, plist, TOML, JSON, EnvFile)

**Atomicity warning:** Task 27 adds `.date`/`.data` cases to `ConfigValue`. All five exhaustive switches over `ConfigValue` (verified by grep, exactly five after Task 27's own edits: `YAMLConfigFormat.build`, `JSONConfigFormat.write`, `TOMLConfigFormat.tomlValue`, `PlistConfigFormat.write`, `ConfigNodeView.body`) must be updated in the SAME commit or the module doesn't compile. Tasks 27–31 are written as separate commits that each keep the build green because Task 27 includes the *minimal* switch additions everywhere; Tasks 28–31 then apply each format's behavioral fix. All proposed code was compile- and behavior-verified against the pinned dependency versions (Yams 5.4.0, TOMLKit 0.6.0).

### Task 27: `ConfigValue` gains `.date`/`.data` cases (raw-lexeme storage)

Decision: raw-lexeme cases (`.date(String)`, `.data(String)`) rather than format-private markers — no `Date`/`Data` conversion means zero re-formatting loss, and `Equatable`/`Sendable` stay auto-derived.

**Files:**
- Modify: `Sources/LumeKit/Config/ConfigValue.swift:6-13`
- Modify (switch exhaustiveness, minimal): `Sources/LumeKit/Config/YAMLConfigFormat.swift` (`build`), `Sources/LumeKit/Config/JSONConfigFormat.swift` (`write`), `Sources/LumeKit/Config/TOMLConfigFormat.swift` (`tomlValue`), `Sources/LumeKit/Config/PlistConfigFormat.swift` (`write`), `Sources/Lume/Viewers/ConfigEditorView.swift` (`ConfigNodeView.body`)
- Test: append to `Tests/LumeKitTests/JSONConfigFormatTests.swift`

- [ ] **Step 1: Replace the enum**

Replace `ConfigValue.swift:6-13` (the enum declaration; `ConfigEntry` etc. unchanged):

```swift
/// An editable structured config value. The in-memory model that structured
/// editors bind to, independent of the on-disk format. Numbers keep their raw
/// lexeme so `1` and `1.0` round-trip exactly; dates and binary data likewise
/// keep their textual form (ISO-ish date lexeme, base64) so formats with
/// native types (plist `<date>`/`<data>`, TOML date/time) round-trip losslessly.
public indirect enum ConfigValue: Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    /// A date/time value, stored as its raw source lexeme (e.g. "2024-06-01").
    case date(String)
    /// Binary data, stored as the base64 text from the source document.
    case data(String)
    case array([ConfigValue])
    case object([ConfigEntry])
}
```

- [ ] **Step 2: Add the minimal new cases to the five switches** (behavioral fixes come in Tasks 28–31)

`YAMLConfigFormat.build` — add before the `.array` case:

```swift
        // Date lexemes stay plain — they re-resolve as YAML timestamps, which
        // `convert` maps back to text either way. Base64 blobs are strings here.
        case let .date(d): return Node(d, Yams.Tag(.str))
        case let .data(d): return Node(d, Yams.Tag(.str))
```

`JSONConfigFormat.write` — add after the `.null` case:

```swift
        case let .date(d):
            // JSON has no date or binary types; both degrade to strings.
            out.append(encodeString(d))
        case let .data(d):
            out.append(encodeString(d))
```

`TOMLConfigFormat.tomlValue` — add after the `.null` case (placeholder semantics until Task 30):

```swift
        case let .date(lexeme): return lexeme   // refined to native TOML dates in Task 30
        case let .data(base64): return base64   // TOML has no binary type; base64 text as string
```

`PlistConfigFormat.write` — add after the `.null` case:

```swift
        case let .date(d):
            out.append("\(pad)<date>\(escape(d))</date>\n")
        case let .data(d):
            out.append("\(pad)<data>\(escape(d))</data>\n")
```

`ConfigNodeView.body` (`Sources/Lume/Viewers/ConfigEditorView.swift:102-134`) — add between `case .bool` and `case .null`:

```swift
        case .date(let d):
            leaf {
                TextField("", text: Binding(get: { d }, set: { value = .date($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
        case .data(let d):
            // Binary payloads aren't editable inline; show the base64 read-only.
            leaf {
                Text(d)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
```

- [ ] **Step 3: Add the degradation test**

Append to `Tests/LumeKitTests/JSONConfigFormatTests.swift`:

```swift
// Formats without native date/data types degrade the new cases to plain
// strings, never crash.
@Test func serializesDateAndDataCasesAsStrings() throws {
    let value = ConfigValue.object([
        ConfigEntry(key: "d", value: .date("2024-06-01")),
        ConfigEntry(key: "b", value: .data("aGVsbG8=")),
    ])
    let out = try JSONConfigFormat.serialize(value)
    #expect(try JSONConfigFormat.parse(out) == .object([
        ConfigEntry(key: "d", value: .string("2024-06-01")),
        ConfigEntry(key: "b", value: .string("aGVsbG8=")),
    ]))
}
```

- [ ] **Step 4: Run full suite — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Config/ConfigValue.swift Sources/LumeKit/Config/YAMLConfigFormat.swift Sources/LumeKit/Config/JSONConfigFormat.swift Sources/LumeKit/Config/TOMLConfigFormat.swift Sources/LumeKit/Config/PlistConfigFormat.swift Sources/Lume/Viewers/ConfigEditorView.swift Tests/LumeKitTests/JSONConfigFormatTests.swift
git commit -m "feat: ConfigValue date/data cases with raw-lexeme storage

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 28: C3 — YAML quotes strings that would retype on round-trip

**Files:**
- Modify: `Sources/LumeKit/Config/YAMLConfigFormat.swift` (`build` + new `scalarStyle`)
- Test: append to `Tests/LumeKitTests/YAMLConfigFormatTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func quotesStringsThatWouldRetypeOnRoundTrip() throws {
    // Fails before the fix: "1.0" re-parses as .number, "true"/"no" as .bool,
    // "null"/"" as .null, "0x1F" as .number.
    let value = ConfigValue.object([
        ConfigEntry(key: "version", value: .string("1.0")),
        ConfigEntry(key: "flag", value: .string("true")),
        ConfigEntry(key: "negative", value: .string("no")),
        ConfigEntry(key: "nothing", value: .string("null")),
        ConfigEntry(key: "hex", value: .string("0x1F")),
        ConfigEntry(key: "empty", value: .string("")),
    ])
    let out = try YAMLConfigFormat.serialize(value)
    #expect(try YAMLConfigFormat.parse(out) == value)
    #expect(out.contains(#"version: "1.0""#))
}

@Test func unambiguousStringsStayUnquoted() throws {
    let value = ConfigValue.object([ConfigEntry(key: "name", value: .string("lume"))])
    let out = try YAMLConfigFormat.serialize(value)
    #expect(out.contains("name: lume"))
    #expect(!out.contains(#""lume""#))
}

@Test func timestampLikeStringsRoundTripUnquoted() throws {
    let value = try YAMLConfigFormat.parse("released: 2024-06-01")
    let out = try YAMLConfigFormat.serialize(value)
    #expect(out.contains("released: 2024-06-01"))
    #expect(!out.contains(#""2024-06-01""#))
    #expect(try YAMLConfigFormat.parse(out) == value)
}
```

- [ ] **Step 2: Run — expect FAIL** (round-trip retypes `"1.0"` etc.)

- [ ] **Step 3: Implement**

Replace `build(_:)` (including Task 27's case additions) with:

```swift
    private static func build(_ value: ConfigValue) -> Node {
        switch value {
        case let .string(s): return Node(s, Yams.Tag(.str), scalarStyle(for: s))
        case let .number(n):
            let tag: Yams.Tag.Name = (n.contains(".") || n.lowercased().contains("e")) ? .float : .int
            return Node(n, Yams.Tag(tag))
        case let .bool(b): return Node(b ? "true" : "false", Yams.Tag(.bool))
        case .null: return Node("null", Yams.Tag(.null))
        // Date lexemes stay plain — they re-resolve as YAML timestamps, which
        // `convert` maps back to text either way. Base64 blobs are strings here.
        case let .date(d): return Node(d, Yams.Tag(.str))
        case let .data(d): return Node(d, Yams.Tag(.str), scalarStyle(for: d))
        case let .array(items): return Node(items.map(build), Yams.Tag(.seq))
        case let .object(entries):
            return Node(entries.map { (Node($0.key, Yams.Tag(.str)), build($0.value)) }, Yams.Tag(.map))
        }
    }

    /// Plain-style emission drops the `!!str` tag, so a string whose text would
    /// re-resolve as another scalar type — "true", "no", "1.0", "null", "0x1F",
    /// "" — must be double-quoted or one save silently changes its type.
    /// Timestamps stay plain: `convert` maps them to `.string` on read anyway,
    /// so quoting would needlessly retype real YAML dates.
    private static func scalarStyle(for s: String) -> Node.Scalar.Style {
        let resolved = Resolver.default.resolveTag(of: Node(s))
        return (resolved == .str || resolved == .timestamp) ? .any : .doubleQuoted
    }
```

(Verified against Yams 5.4.0: `Node.init(_:_:_:_:)` with `Node.Scalar.Style`, public `Resolver.default.resolveTag(of:)`; the emitter's `plain_implicit=1, quoted_implicit=1` means style alone controls quoting. Mapping keys need no quoting: parse reads keys via `.string`, which returns the lexeme regardless of resolved tag.)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Config/YAMLConfigFormat.swift Tests/LumeKitTests/YAMLConfigFormatTests.swift
git commit -m "fix: quote YAML strings whose plain form would change type (AUDIT C3)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 29: C4 + JSON hardening — surrogate pairs, strict number grammar, depth limit

**Files:**
- Modify: `Sources/LumeKit/Config/JSONConfigFormat.swift` (`JSONParser` struct: state, `parseValue`, `parseNumber`, `parseUnicodeEscape`)
- Test: append to `Tests/LumeKitTests/JSONConfigFormatTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesSurrogatePairEscapes() throws {
    // Fails before the fix: U+1F600 escapes as \uD83D\uDE00 (what
    // JSONSerialization emits for emoji) and the parser threw on the
    // high surrogate.
    let value = try JSONConfigFormat.parse(#"{"emoji": "\uD83D\uDE00"}"#)
    guard case let .object(entries) = value else {
        Issue.record("expected object, got \(value)")
        return
    }
    #expect(entries[0].value == .string("😀"))
    // And the parsed value survives a serialize → parse cycle.
    let out = try JSONConfigFormat.serialize(value)
    #expect(try JSONConfigFormat.parse(out) == value)
}

@Test func throwsOnLoneOrMalformedSurrogates() {
    // Lone high surrogate at end of string.
    #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83D""#) }
    // Lone low surrogate.
    #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uDE00""#) }
    // High surrogate followed by a plain character.
    #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83Dx""#) }
    // High surrogate followed by a non-\u escape.
    #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83D\n""#) }
    // High surrogate followed by another high surrogate.
    #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(#""\uD83D\uD83D""#) }
}

@Test func bmpEscapesStillParse() throws {
    #expect(try JSONConfigFormat.parse(#""\u00e9""#) == .string("é"))
}

@Test func rejectsGarbageNumberLexemes() {
    // Fails before the fix: the charset scan accepted these and serialize
    // would emit invalid JSON.
    for bad in ["1.2.3", "+1", "01", ".5", "1.", "1e", "1e+", "--1", "0x10", "1e5e5", "-"] {
        #expect(throws: ConfigParseError.self, "expected '\(bad)' to be rejected") {
            try JSONConfigFormat.parse(bad)
        }
    }
}

@Test func acceptsValidNumberLexemesUnchanged() throws {
    #expect(try JSONConfigFormat.parse("0") == .number("0"))
    #expect(try JSONConfigFormat.parse("123") == .number("123"))
    #expect(try JSONConfigFormat.parse("0.1") == .number("0.1"))
    #expect(try JSONConfigFormat.parse("-0.5e+10") == .number("-0.5e+10"))
}

@Test func throwsInsteadOfCrashingOnDeepNesting() {
    // Fails (by crashing) before the fix: 10k nested arrays overflow the stack.
    let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
    #expect(throws: ConfigParseError.self) { try JSONConfigFormat.parse(deep) }
}

@Test func allowsReasonableNestingDepth() throws {
    let ok = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
    #expect(throws: Never.self) { try JSONConfigFormat.parse(ok) }
}
```

(If the toolchain's `#expect(throws:_:)` overload lacks the message parameter, drop the message argument.)

- [ ] **Step 2: Run — expect FAIL** (surrogate test throws; garbage numbers accepted; deep nesting crashes the test process — if so, temporarily skip that one test until Step 3, then re-enable)

- [ ] **Step 3: Implement**

In `JSONConfigFormat.swift`, inside `private struct JSONParser`:

(a) Replace the state declaration:

```swift
/// A minimal recursive-descent JSON parser that keeps object keys in source order.
private struct JSONParser {
    private let scalars: [Character]
    private var i = 0
    private var depth = 0
    /// Deeper nesting than any sane config file; prevents a stack overflow on
    /// adversarial input (the parser recurses once per nesting level).
    private static let maxDepth = 256

    init(_ text: String) { scalars = Array(text) }
```

(b) Replace `parseValue`:

```swift
    private mutating func parseValue() throws -> ConfigValue {
        skipWhitespace()
        guard let c = peek() else { throw ConfigParseError("unexpected end of input") }
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else {
            throw ConfigParseError("nesting exceeds \(Self.maxDepth) levels")
        }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseLiteral("null"); return .null
        default: return .number(try parseNumber())
        }
    }
```

(c) Replace `parseNumber` and add the grammar validator:

```swift
    private mutating func parseNumber() throws -> String {
        let start = i
        while let c = peek(), "0123456789+-.eE".contains(c) { i += 1 }
        guard i > start else { throw ConfigParseError("invalid number at \(start)") }
        let lexeme = String(scalars[start..<i])
        guard Self.isValidJSONNumber(lexeme) else {
            throw ConfigParseError("invalid number '\(lexeme)' at \(start)")
        }
        return lexeme
    }

    /// Strict JSON number grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
    /// The greedy charset scan above accepts lexemes like `1.2.3` or `--1`;
    /// rejecting them here keeps serialized output valid JSON.
    private static func isValidJSONNumber(_ s: String) -> Bool {
        var rest = Substring(s)
        func digit() -> Bool {
            guard let c = rest.first, c.isASCII, c.isNumber else { return false }
            rest.removeFirst()
            return true
        }
        if rest.first == "-" { rest.removeFirst() }
        // Integer part: 0, or a non-zero digit followed by more digits.
        guard let lead = rest.first else { return false }
        guard digit() else { return false }
        if lead != "0" { while digit() {} }
        // Optional fraction: '.' then 1+ digits.
        if rest.first == "." {
            rest.removeFirst()
            guard digit() else { return false }
            while digit() {}
        }
        // Optional exponent: e/E, optional sign, then 1+ digits.
        if rest.first == "e" || rest.first == "E" {
            rest.removeFirst()
            if rest.first == "+" || rest.first == "-" { rest.removeFirst() }
            guard digit() else { return false }
            while digit() {}
        }
        return rest.isEmpty
    }
```

(d) Replace `parseUnicodeEscape` (currently `:178-186`) and add `parseHexCodeUnit`:

```swift
    private mutating func parseUnicodeEscape() throws -> Character {
        let first = try parseHexCodeUnit()
        // High surrogate: must be immediately followed by an escaped low
        // surrogate (\uDC00–\uDFFF); the pair combines into one scalar.
        if (0xD800...0xDBFF).contains(first) {
            guard i + 1 < scalars.count, scalars[i] == "\\", scalars[i + 1] == "u" else {
                throw ConfigParseError("unpaired high surrogate \\u\(String(format: "%04X", first))")
            }
            i += 2 // consume \u
            let second = try parseHexCodeUnit()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw ConfigParseError("expected low surrogate, got \\u\(String(format: "%04X", second))")
            }
            let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(code) else {
                throw ConfigParseError("invalid surrogate pair")
            }
            return Character(scalar)
        }
        // A lone low surrogate is never a valid scalar.
        guard !(0xDC00...0xDFFF).contains(first), let scalar = Unicode.Scalar(first) else {
            throw ConfigParseError("unpaired low surrogate \\u\(String(format: "%04X", first))")
        }
        return Character(scalar)
    }

    private mutating func parseHexCodeUnit() throws -> UInt32 {
        guard i + 4 <= scalars.count else { throw ConfigParseError("short \\u escape") }
        let hex = String(scalars[i..<i + 4])
        guard let code = UInt32(hex, radix: 16) else {
            throw ConfigParseError("invalid \\u escape \(hex)")
        }
        i += 4
        return code
    }
```

(Serialization is unaffected: `encodeString` emits non-BMP characters as raw UTF-8, which is valid JSON and re-parses identically.)

- [ ] **Step 4: Run — expect PASS (all JSON tests, including the previously-skipped deep-nesting one)**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Config/JSONConfigFormat.swift Tests/LumeKitTests/JSONConfigFormatTests.swift
git commit -m "fix: JSON surrogate pairs, strict number grammar, recursion depth cap (AUDIT C4)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 30: TOML — native date round-trip; throw on garbage numbers

**Files:**
- Modify: `Sources/LumeKit/Config/TOMLConfigFormat.swift:20-69` (`serialize`, `convert`, `buildTable`, `tomlValue`)
- Test: append to `Tests/LumeKitTests/TOMLConfigFormatTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func roundTripsDateAndTimeValuesUnquoted() throws {
    // Fails before the fix: dates re-serialized as quoted strings
    // (released = "2024-06-01"), changing the TOML value type on save.
    let value = try TOMLConfigFormat.parse("""
    released = 2024-06-01
    at = 07:32:00
    stamp = 1979-05-27T07:32:00Z
    """)
    guard case let .object(entries) = value else {
        Issue.record("expected object, got \(value)"); return
    }
    let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    #expect(byKey["released"] == .date("2024-06-01"))
    #expect(byKey["at"] == .date("07:32:00"))
    let out = try TOMLConfigFormat.serialize(value)
    #expect(out.contains("released = 2024-06-01"))
    #expect(!out.contains(#""2024-06-01""#))
    #expect(out.contains("at = 07:32:00"))
    #expect(out.contains("stamp = 1979-05-27T07:32:00Z"))
    #expect(try TOMLConfigFormat.parse(out) == value)
}

@Test func throwsOnUnparseableNumberLexeme() {
    // Fails before the fix: "1.2.3" silently serialized as 0.
    #expect(throws: ConfigParseError.self) {
        try TOMLConfigFormat.serialize(.object([
            ConfigEntry(key: "n", value: .number("1.2.3")),
        ]))
    }
}

@Test func throwsOnUnparseableDateLexeme() {
    #expect(throws: ConfigParseError.self) {
        try TOMLConfigFormat.serialize(.object([
            ConfigEntry(key: "d", value: .date("not-a-date")),
        ]))
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

Replace `serialize`, `convert`, `buildTable`, `tomlValue` (`:20-69`, including Task 27's placeholder cases):

```swift
    public static func serialize(_ value: ConfigValue) throws -> String {
        guard case let .object(entries) = value else {
            throw ConfigParseError("TOML root must be a table")
        }
        return try buildTable(entries).convert()
    }

    private static func convert(_ value: TOMLValueConvertible) -> ConfigValue {
        switch value.type {
        case .table:
            let table = value.table ?? TOMLTable()
            return .object(table.keys.compactMap { key in
                table[key].map { ConfigEntry(key: key, value: convert($0)) }
            })
        case .array:
            return .array((value.array ?? []).map(convert))
        case .string:
            return .string(value.string ?? "")
        case .int:
            return .number(String(value.int ?? 0))
        case .double:
            return .number(String(value.double ?? 0))
        case .bool:
            return .bool(value.bool ?? false)
        case .date, .time, .dateTime:
            // Keep the TOML lexeme so serialization can emit a native
            // (unquoted) date/time instead of retyping it to a string.
            return .date(value.debugDescription)
        }
    }

    private static func buildTable(_ entries: [ConfigEntry]) throws -> TOMLTable {
        let table = TOMLTable()
        for entry in entries {
            table[entry.key] = try tomlValue(entry.value)
        }
        return table
    }

    private static func tomlValue(_ value: ConfigValue) throws -> TOMLValueConvertible {
        switch value {
        case let .string(s): return s
        case let .number(n):
            if !n.contains("."), !n.lowercased().contains("e"), let i = Int(n) { return i }
            if let d = Double(n) { return d }
            throw ConfigParseError("not a valid TOML number: '\(n)'")
        case let .bool(b): return b
        case .null: return ""   // TOML has no null; closest stable mapping is empty string
        case let .date(lexeme):
            // Re-parse the lexeme through TOMLKit so it serializes as a native
            // date/time. Copy the value structs out — the probe table is temporary.
            guard let probe = try? TOMLTable(string: "v = \(lexeme)"), let v = probe["v"] else {
                throw ConfigParseError("not a valid TOML date/time: '\(lexeme)'")
            }
            if let dateTime = v.dateTime { return dateTime }
            if let date = v.date { return date }
            if let time = v.time { return time }
            throw ConfigParseError("not a valid TOML date/time: '\(lexeme)'")
        case let .data(base64):
            return base64   // TOML has no binary type; keep the base64 text as a string
        case let .array(items): return TOMLArray(try items.map(tomlValue))
        case let .object(entries): return try buildTable(entries)
        }
    }
```

Known TOMLKit 0.6.0 quirk (verified): a *local* date-time (`1979-05-27T07:32:00`, no offset) gets a `Z` appended by `debugDescription`, so local date-times become UTC offset date-times across a round-trip — strictly better than the current string retyping. The `dateTime` check must come first. `serialize` already `throws`, so no public-signature change; `ConfigEditorView.reserialize` uses `try?`, so a garbage lexeme typed in the editor simply doesn't push text instead of writing `0`.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Config/TOMLConfigFormat.swift Tests/LumeKitTests/TOMLConfigFormatTests.swift
git commit -m "fix: TOML native date round-trip; throw on unparseable numbers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 31: Plist — native `<date>`/`<data>` round-trip + CDATA handler

**Files:**
- Modify: `Sources/LumeKit/Config/PlistConfigFormat.swift` (`didEndElement` data/date cases; add `foundCDATA`)
- Test: append to `Tests/LumeKitTests/PlistConfigFormatTests.swift` (add `import Foundation` at the top if absent)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func roundTripsDataAndDateAsNativeTags() throws {
    // Fails before the fix: <date>/<data> parsed to .string and re-serialized
    // as <string>, silently retyping the plist on save.
    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Stamp</key>
        <date>2024-06-01T07:32:00Z</date>
        <key>Blob</key>
        <data>aGVsbG8=</data>
    </dict>
    </plist>
    """
    let value = try PlistConfigFormat.parse(sample)
    guard case let .object(entries) = value else {
        Issue.record("expected object, got \(value)"); return
    }
    #expect(entries[0].value == .date("2024-06-01T07:32:00Z"))
    #expect(entries[1].value == .data("aGVsbG8="))
    let out = try PlistConfigFormat.serialize(value)
    #expect(out.contains("<date>2024-06-01T07:32:00Z</date>"))
    #expect(out.contains("<data>aGVsbG8=</data>"))
    #expect(try PlistConfigFormat.parse(out) == value)
    // The emitted plist must stay readable by Apple's own parser, with types intact.
    let plist = try PropertyListSerialization.propertyList(
        from: Data(out.utf8), format: nil
    )
    let dict = try #require(plist as? [String: Any])
    #expect(dict["Stamp"] is Date)
    #expect(dict["Blob"] is Data)
}

@Test func preservesCDATAContent() throws {
    // Fails before the fix: missing foundCDATA handler parsed the string to ""
    // and saving deleted the content.
    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Story</key>
        <string><![CDATA[a <b> & c]]></string>
    </dict>
    </plist>
    """
    let value = try PlistConfigFormat.parse(sample)
    #expect(value == .object([ConfigEntry(key: "Story", value: .string("a <b> & c"))]))
    // Round-trip re-escapes with entities instead of CDATA — content survives.
    let out = try PlistConfigFormat.serialize(value)
    #expect(try PlistConfigFormat.parse(out) == value)
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

In `PlistBuilder`'s `didEndElement` (currently `:108-134`), replace the combined data/date case

```swift
        case "data", "date": capturing = false; emit(.string(text.trimmingCharacters(in: .whitespacesAndNewlines)))
```

with:

```swift
        case "data": capturing = false; emit(.data(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "date": capturing = false; emit(.date(text.trimmingCharacters(in: .whitespacesAndNewlines)))
```

After `foundCharacters` (currently `:105-107`), add:

```swift
    /// XMLParser routes `<![CDATA[…]]>` here, not to `foundCharacters` —
    /// without this, CDATA content inside a leaf silently parses to "".
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard capturing else { return }
        guard let decoded = String(data: CDATABlock, encoding: .utf8) else {
            failure = "CDATA block is not valid UTF-8"
            return
        }
        text += decoded
    }
```

(The `write` cases for `.date`/`.data` landed in Task 27.)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Config/PlistConfigFormat.swift Tests/LumeKitTests/PlistConfigFormatTests.swift
git commit -m "fix: plist date/data native round-trip and CDATA handling

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 32: EnvFile — CRLF handling

**Files:**
- Modify: `Sources/LumeKit/Config/EnvFile.swift:24-40` (`parse`)
- Test: `Tests/LumeKitTests/EnvFileTests.swift` (new — EnvFile was fully untested)

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeKitTests/EnvFileTests.swift`:

```swift
import Testing
@testable import LumeKit

@Suite struct EnvFileTests {
    @Test func parsesEntriesCommentsAndBlanks() {
        let lines = EnvFile.parse("""
        # config
        HOST=localhost

        export PORT=5432
        NAME="lume app"
        TOKEN='s3cret'
        """)
        #expect(lines[0] == .comment("# config"))
        #expect(lines[1] == .entry(EnvEntry(key: "HOST", value: "localhost")))
        #expect(lines[2] == .blank)
        #expect(EnvFile.entries(from: lines) == [
            EnvEntry(key: "HOST", value: "localhost"),
            EnvEntry(key: "PORT", value: "5432"),
            EnvEntry(key: "NAME", value: "lume app"),
            EnvEntry(key: "TOKEN", value: "s3cret"),
        ])
    }

    @Test func parsesCRLFFilesWithoutCarriageReturnLeakage() {
        // Fails before the fix: split on "\n" left a trailing \r on every line,
        // so values gained \r, quote-stripping failed, and the blank line
        // (containing just \r) misclassified.
        let lines = EnvFile.parse("A=1\r\nB=\"two\"\r\n\r\n# note\r\nC=3")
        #expect(EnvFile.entries(from: lines) == [
            EnvEntry(key: "A", value: "1"),
            EnvEntry(key: "B", value: "two"),
            EnvEntry(key: "C", value: "3"),
        ])
        #expect(lines[2] == .blank)
        #expect(lines[3] == .comment("# note"))
    }

    @Test func lineWithoutEqualsBecomesComment() {
        #expect(EnvFile.parse("not an assignment") == [.comment("not an assignment")])
    }

    @Test func stripsOnlyMatchingSurroundingQuotes() {
        #expect(EnvFile.stripSurroundingQuotes(#""x""#) == "x")
        #expect(EnvFile.stripSurroundingQuotes("'x'") == "x")
        #expect(EnvFile.stripSurroundingQuotes(#""x'"#) == #""x'"#)
        #expect(EnvFile.stripSurroundingQuotes(#"""#) == #"""#)
    }

    @Test func masksCapAtTwentyFourDots() {
        #expect(EnvFile.mask("abc") == "•••")
        #expect(EnvFile.mask(String(repeating: "x", count: 100)).count == 24)
    }
}
```

(Verify `entries(from:)`, `stripSurroundingQuotes`, and `mask` exist with these exact names/signatures in `EnvFile.swift` when editing — adjust the test calls to the real API if they differ; the CRLF test is the must-have.)

- [ ] **Step 2: Run — expect FAIL on the CRLF test**

- [ ] **Step 3: Implement — one-line change in `parse`**

Replace the split line:

```swift
        text.split(separator: "\n", omittingEmptySubsequences: false).map { rawSub in
```

with:

```swift
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { rawSub in
```

and update the doc comment above `parse` to:

```swift
    /// Parse `.env` text into ordered lines, preserving comments and blanks.
    /// Splits on any newline grapheme (`\n`, `\r\n`, `\r`) so CRLF files don't
    /// leak a trailing `\r` into values or defeat quote-stripping.
```

(In Swift, `"\r\n"` is a single `Character` grapheme with `isNewline == true`, so CRLF, lone `\r`, and lone `\n` all act as one separator; LF-only files behave identically. EnvEditorView and SecretDetector consume `parse` output — values no longer carry `\r`.)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Config/EnvFile.swift Tests/LumeKitTests/EnvFileTests.swift Lume.xcodeproj
git commit -m "fix: parse CRLF .env files correctly; add EnvFile test suite

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 7 — Routing, selection, undo, dead code

### Task 33: DocumentRouter as single source of truth (+ `configEditor` case)

**Files:**
- Modify: `Sources/LumeKit/Document/DocumentRouter.swift` (full file)
- Modify: `Sources/Lume/ContentView.swift:74-94` (`DetailView.viewer(for:)`)
- Modify: `Tests/LumeKitTests/DocumentRouterTests.swift` (full replacement)

- [ ] **Step 1: Write the failing tests** — replace `DocumentRouterTests.swift`:

```swift
import Testing
@testable import LumeKit

@Test func routesEachKindToExpectedViewer() {
    #expect(DocumentRouter.viewer(for: .markdown) == .markdownEditor)
    #expect(DocumentRouter.viewer(for: .env) == .envEditor)
    #expect(DocumentRouter.viewer(for: .code) == .codeViewer)
    #expect(DocumentRouter.viewer(for: .pdf) == .pdf)
    #expect(DocumentRouter.viewer(for: .image) == .image)
    #expect(DocumentRouter.viewer(for: .previewable) == .quickLook)
    #expect(DocumentRouter.viewer(for: .html) == .html)
    #expect(DocumentRouter.viewer(for: .unsupported) == .quickLook)
}

@Test func filenameRoutingClaimsConfigFormats() {
    // Every registered ConfigRegistry extension lands on the structured editor,
    // even though json/yaml/toml detect as `.code`.
    #expect(DocumentRouter.viewer(forFilename: "package.json") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "Info.plist") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "config.yaml") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "ci.yml") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "Cargo.toml") == .configEditor)
}

@Test func filenameRoutingPrefersEnvOverConfig() {
    // .env* matches by NAME before extension logic — ".env.yaml" must NOT fall
    // into the YAML config editor (it's a masked secrets file).
    #expect(DocumentRouter.viewer(forFilename: ".env") == .envEditor)
    #expect(DocumentRouter.viewer(forFilename: ".env.local") == .envEditor)
    #expect(DocumentRouter.viewer(forFilename: ".env.yaml") == .envEditor)
}

@Test func filenameRoutingFallsThroughToKind() {
    #expect(DocumentRouter.viewer(forFilename: "README.md") == .markdownEditor)
    #expect(DocumentRouter.viewer(forFilename: "main.swift") == .codeViewer)
    #expect(DocumentRouter.viewer(forFilename: "report.pdf") == .pdf)
    #expect(DocumentRouter.viewer(forFilename: "photo.png") == .image)
    #expect(DocumentRouter.viewer(forFilename: "index.html") == .html)
    #expect(DocumentRouter.viewer(forFilename: "report.docx") == .quickLook)
    #expect(DocumentRouter.viewer(forFilename: "mystery.bin") == .quickLook)
}

@Test func editorsAreEditableViewersAreNot() {
    #expect(DocumentViewer.markdownEditor.isEditable)
    #expect(DocumentViewer.envEditor.isEditable)
    #expect(DocumentViewer.configEditor.isEditable)
    #expect(!DocumentViewer.codeViewer.isEditable)
    #expect(!DocumentViewer.pdf.isEditable)
    #expect(!DocumentViewer.image.isEditable)
    #expect(!DocumentViewer.quickLook.isEditable)
    #expect(!DocumentViewer.html.isEditable)
}
```

(If the current `DocumentRouterTests.swift` contains additional `FileKind.detect` assertions, keep them.)

- [ ] **Step 2: Run — expect FAIL** (`configEditor` / `viewer(forFilename:)` missing)

- [ ] **Step 3: Implement — replace `DocumentRouter.swift`:**

```swift
import Foundation

/// The concrete surface used to display a document.
public enum DocumentViewer: Equatable, Sendable {
    case markdownEditor   // styled-source text editor (editable)
    case envEditor        // native masked key=value editor (editable)
    case configEditor     // structured config editor — JSON/plist/YAML/TOML (editable)
    case codeViewer       // read-only syntax-highlighted source
    case pdf              // paginated PDF document viewer
    case image            // native, layer-backed image viewer (GPU-composited)
    case quickLook        // system preview (docx/office/unsupported long-tail)
    case html             // rendered web content

    public var isEditable: Bool {
        switch self {
        case .markdownEditor, .envEditor, .configEditor: return true
        case .codeViewer, .pdf, .image, .quickLook, .html: return false
        }
    }
}

public enum DocumentRouter {
    /// Route by kind alone. Prefer `viewer(forFilename:)`, which also claims
    /// structured config files; this overload can't see them (config formats
    /// are matched by extension, several of which detect as `.code`).
    public static func viewer(for kind: FileKind) -> DocumentViewer {
        switch kind {
        case .markdown: return .markdownEditor
        case .env: return .envEditor
        case .code: return .codeViewer
        case .pdf: return .pdf
        case .image: return .image
        case .previewable: return .quickLook
        case .html: return .html
        case .unsupported: return .quickLook
        }
    }

    /// Single source of truth for the detail pane. Precedence:
    ///   1. `.env` / `.env.*` (matched by NAME — ".env.yaml" is env, not YAML),
    ///   2. any `ConfigRegistry` format claiming the extension → `configEditor`,
    ///   3. plain kind routing.
    public static func viewer(forFilename name: String) -> DocumentViewer {
        let kind = FileKind.detect(filename: name)
        if kind == .env { return .envEditor }
        if ConfigRegistry.format(forFilename: name) != nil { return .configEditor }
        return viewer(for: kind)
    }
}
```

(Case rename to fully capability-oriented names deferred: the UI-vocabulary complaint lived in the comments, which this rewrite fixes; renaming `.pdf` → `.pdfViewer` etc. would be diff noise.)

Replace `DetailView.viewer(for:)` in `ContentView.swift` (currently `:74-94`):

```swift
    @ViewBuilder
    private func viewer(for url: URL) -> some View {
        switch DocumentRouter.viewer(forFilename: url.lastPathComponent) {
        case .envEditor:
            EnvEditorView()
        case .configEditor:
            ConfigEditorView()
        case .markdownEditor, .codeViewer:
            if app.documentText != nil { EditorView() } else { loading }
        case .pdf:
            PDFViewer(url: url)
        case .image:
            ImageViewer(url: url)
        case .html:
            HTMLViewer(url: url)
        case .quickLook:
            QuickLookViewer(url: url)
        }
    }
```

(Behavior parity: old code switched on `app.selectedKind`, which `select(_:)` sets via the same `FileKind.detect(filename:)` for the same URL.)

- [ ] **Step 4: Run + build — expect PASS. Manual: `package.json` → config editor; `.env.local` → env editor; `README.md` → editor; `report.docx` → QuickLook; `photo.png` → image viewer — identical to before.**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Document/DocumentRouter.swift Sources/Lume/ContentView.swift Tests/LumeKitTests/DocumentRouterTests.swift
git commit -m "refactor: route the detail pane through DocumentRouter (single source of truth)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 34: `RowSelection.revalidate` honors fail-open for GROUPS ids

**Files:**
- Modify: `Sources/LumeKit/Selection/RowSelection.swift:90-116`
- Test: append to `Tests/LumeKitTests/RowSelectionTests.swift`

- [ ] **Step 1: Write the failing tests** (append inside `RowSelectionTests` after the existing revalidate block, matching its `private static let` id conventions):

```swift
    // MARK: revalidate — GROUPS grammar (group|g|tag, groupfile|f|tag|path)

    private static let groupHeader = GroupRowID.headerID(tagName: "api")
    private static let groupFileA = GroupRowID.fileID(tagName: "api", path: "/x/a.md")
    private static let groupFileB = GroupRowID.fileID(tagName: "api", path: "/x/b.md")

    @Test func revalidateKeepsGroupHeaders() {
        // A header is navigation (like a directory) — never dropped by a filter,
        // even an empty `allowed` set.
        let r = RowSelection.revalidate(selection: [Self.groupHeader],
                                        anchor: Self.groupHeader, focus: Self.groupHeader,
                                        allowed: Set<String>())
        #expect(r.selection == [Self.groupHeader])
        #expect(r.anchor == Self.groupHeader)
        #expect(r.focus == Self.groupHeader)
    }

    @Test func revalidateKeepsGroupFileWithAllowedPath() {
        let r = RowSelection.revalidate(selection: [Self.groupFileA],
                                        anchor: Self.groupFileA, focus: Self.groupFileA,
                                        allowed: ["/x/a.md"])
        #expect(r.selection == [Self.groupFileA])
        #expect(r.anchor == Self.groupFileA)
        #expect(r.focus == Self.groupFileA)
    }

    @Test func revalidateDropsGroupFileWithDisallowedPath() {
        let r = RowSelection.revalidate(selection: [Self.groupFileA, Self.groupFileB],
                                        anchor: Self.groupFileB, focus: Self.groupFileB,
                                        allowed: ["/x/a.md"])
        #expect(r.selection == [Self.groupFileA])
        #expect(r.anchor == nil)   // anchor pointed at dropped group file
        #expect(r.focus == nil)
    }

    @Test func revalidateGroupFilePathWithPipeDecodesCorrectly() {
        // The path field wins the remainder; "|" inside it is not structural.
        let id = GroupRowID.fileID(tagName: "api", path: "/x/a|b.md")
        let r = RowSelection.revalidate(selection: [id], anchor: id, focus: id,
                                        allowed: ["/x/a|b.md"])
        #expect(r.selection == [id])
        #expect(r.anchor == id)
        #expect(r.focus == id)
    }

    @Test func revalidateMixedGrammarsFilterBySameAllowedSet() {
        // Browser row, group row, and header for the same filter pass coexist:
        // both file rows key off the same real path; the header always stays.
        let r = RowSelection.revalidate(
            selection: [Self.fileA, Self.fileB, Self.groupFileA, Self.groupFileB, Self.groupHeader],
            anchor: nil, focus: nil,
            allowed: ["/x/a.md"])
        #expect(r.selection == [Self.fileA, Self.groupFileA, Self.groupHeader])
    }
```

(Verify the existing tests' browser-id constants are named `fileA`/`fileB` with path `/x/a.md`/`/x/b.md` — adjust the mixed-grammar test to the file's actual constants. Verify `GroupRowID.headerID/fileID/decode` spellings against `GroupRowID.swift`.)

- [ ] **Step 2: Run — expect FAIL** (GROUPS ids wrongly dropped)

- [ ] **Step 3: Implement** — replace `revalidate` (`:90-116`):

```swift
    /// Drop now-hidden FILE rows from a selection after a tag filter changes,
    /// mirroring `FileTreeView.visibleChildren`. Two id grammars are understood:
    ///   • browser/pinned — "section|d-or-f|path": "d" rows stay (directories are
    ///     always navigable); "f" rows survive only if their path is in `allowed`
    ///     (paths may contain "|", so split at most twice).
    ///   • GROUPS (`GroupRowID`) — "group|g|<tag>" headers stay (navigable, like
    ///     directories); "groupfile|f|<tag>|<path>" rows survive only if their
    ///     REAL file path is in `allowed`.
    /// Ids we can't decode are kept (fail open — never silently drop).
    /// Returns the surviving selection plus revalidated anchor/focus (each cleared
    /// to nil if it was dropped). When `allowed` is nil, NOTHING is filtered (no
    /// active filter) and the inputs pass through unchanged.
    public static func revalidate(selection: Set<String>,
                                  anchor: String?,
                                  focus: String?,
                                  allowed: Set<String>?) -> (selection: Set<String>,
                                                             anchor: String?,
                                                             focus: String?) {
        guard let allowed else { return (selection, anchor, focus) }
        func survives(_ id: String) -> Bool {
            // GROUPS grammar first: those ids ALSO split into 3 "|" parts, so the
            // generic decode below would misread them (a header's tag name lands
            // in the path slot and gets dropped — violating fail-open).
            if let group = GroupRowID.decode(id) {
                switch group {
                case .header:
                    return true                          // header → always keep
                case .file(_, let path):
                    return allowed.contains(path)        // group file → real path must be allowed
                }
            }
            let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return true } // undecodable → keep
            if parts[1] == "d" { return true }          // directory → always keep
            return allowed.contains(String(parts[2]))   // file → must be allowed
        }
        let kept = selection.filter(survives)
        let newAnchor = anchor.flatMap { survives($0) ? $0 : nil }
        let newFocus = focus.flatMap { survives($0) ? $0 : nil }
        return (kept, newAnchor, newFocus)
    }
```

(Verify `GroupRowID.decode`'s actual case shapes against `GroupRowID.swift` and adjust the pattern match if its associated values differ. Existing browser-grammar tests must keep passing untouched — `GroupRowID.decode` returns nil for `browser|…` ids.)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Selection/RowSelection.swift Tests/LumeKitTests/RowSelectionTests.swift
git commit -m "fix: revalidate honors fail-open for GROUPS-grammar row ids

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 35: ⌘Z routing — responder-chain undo; dedicated editor undo stack

Approach (simplest correct for SwiftUI/macOS 14): **stop replacing `.undoRedo`**. The default Edit ▸ Undo/Redo items dispatch `undo:`/`redo:` through the responder chain and AppKit re-validates enablement on every menu open — fixing both the routing and the stale enablement. File ops register on the **window's** undo manager; the editor's `NSTextView` gets its own dedicated undo manager via its delegate. All four file edits land together — removing the `CommandGroup` while `AppState.undoManager` is still a detached `let` would make file-ops undo unreachable.

**Files:**
- Modify: `Sources/Lume/LumeCommands.swift:24-32`
- Modify: `Sources/Lume/AppState.swift:75-78`, `:925-930`
- Modify: `Sources/Lume/ContentView.swift` (undo-manager wiring)
- Modify: `Sources/Lume/EditorView.swift:46-81`

- [ ] **Step 1: LumeCommands** — delete the `CommandGroup(replacing: .undoRedo)` block (`:24-32`), leaving:

```swift
        // Edit — Undo/Redo intentionally NOT replaced. The default items resolve
        // `undo:`/`redo:` through the responder chain: a focused text view gets
        // typing undo (its own manager — see EditorView.Coordinator), everything
        // else reaches the window's undo manager, where file ops register (see
        // ContentView / AppState.attachUndoManager). AppKit re-validates the
        // items on every menu open, so enablement can't go stale.
```

- [ ] **Step 2: AppState** — replace `:75-78`:

```swift
    /// Accumulates type-ahead characters; reset after a short idle by the view.
    var typeaheadBuffer = ""
    /// The undo manager backing file operations (⌘Z): the window's undo manager,
    /// attached from ContentView, so the standard Edit ▸ Undo/Redo items reach
    /// it through the responder chain whenever a text view doesn't have focus.
    private(set) weak var undoManager: UndoManager?

    /// Adopt the window's undo manager for file operations.
    func attachUndoManager(_ manager: UndoManager?) {
        undoManager = manager
    }
```

and replace `registerUndo` (`:925-930`):

```swift
    // MARK: Undo plumbing

    private func registerUndo(_ name: String, _ action: @escaping () -> Void) {
        undoManager?.registerUndo(withTarget: self) { _ in action() }
        undoManager?.setActionName(name)
    }
```

- [ ] **Step 3: ContentView** — add the wiring to the body produced by Tasks 4/13/26 (property + one modifier; everything else stays):

Add the property below `@Environment(AppState.self) private var app`:

```swift
    @Environment(\.undoManager) private var undoManager
```

Add directly after `.modifier(ModifierPeekMonitor())`:

```swift
        // Route file-ops undo through the window's undo manager so the default
        // Edit ▸ Undo/Redo items (responder-chain based) can reach it.
        .onChange(of: undoManager, initial: true) { _, manager in
            app.attachUndoManager(manager)
        }
```

- [ ] **Step 4: EditorView** — replace `updateNSView` + the Coordinator head (`:46-81`; rest of Coordinator unchanged):

```swift
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let incoming = app.documentText ?? ""
        // Only replace storage when the model changed externally (file switch),
        // not on every keystroke — preserves cursor + undo.
        if textView.string != incoming {
            textView.string = incoming
            context.coordinator.clearUndoHistory()
            context.coordinator.highlight(textView)
            // Open a freshly-selected document ready to type — no extra click needed.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let app: AppState
        weak var textView: NSTextView?
        private var highlightWorkItem: DispatchWorkItem?
        /// Dedicated undo stack for typing. Without it, NSTextView falls back to
        /// the window's undo manager — the file-ops stack — and ⌘Z mid-typing
        /// could re-trash a file instead of undoing keystrokes.
        private let textUndoManager = UndoManager()

        init(app: AppState) { self.app = app }

        /// NSTextView asks its delegate for an undo manager (`allowsUndo`).
        func undoManager(for view: NSTextView) -> UndoManager? { textUndoManager }

        /// Drop typing history when the model replaces the document (file switch).
        func clearUndoHistory() { textUndoManager.removeAllActions() }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            app.documentTextChanged(textView.string)
            // Debounce re-highlighting while typing.
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
```

- [ ] **Step 5: Build + manual verification**

(1) Type "abc" in the editor, ⌘Z → last keystroke undone, no file trashed. (2) Sidebar focused, trash a file, ⌘Z → restored from Trash. (3) Edit menu before/after a trash: "Undo Move to Trash" enabled/disabled correctly each open. (4) Switch files, ⌘Z → no bleed of previous file's keystrokes. (5) Trash while editor focused: ⌘Z undoes typing (standard focus-scoped undo); click sidebar, ⌘Z restores the file.

- [ ] **Step 6: Commit**

```bash
git add Sources/Lume/LumeCommands.swift Sources/Lume/AppState.swift Sources/Lume/ContentView.swift Sources/Lume/EditorView.swift
git commit -m "fix: responder-chain undo routing; dedicated editor undo stack

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 36: Dead code removal

Grep-verified: `AppState.files` has zero member accesses; `FileServicing.read/write` are called by nothing (the test spy's pass-throughs exist only for conformance; `TextDocument` uses `NSFileCoordinator`); `TagSuggest` is referenced only by its own file (the app built different, contains-based suggestion logic in DocumentTagBar).

**Files:**
- Modify: `Sources/Lume/AppState.swift` (delete `private let files = FileService()`)
- Modify: `Sources/LumeKit/FileSystem/FileService.swift` (slim protocol, delete `read`/`write` bodies)
- Modify: `Tests/LumeKitTests/FileSystemCacheTests.swift:7-18` (slim the spy)
- Delete: `Sources/LumeKit/Library/TagSuggest.swift`

- [ ] **Step 1: Implement**

In `AppState.swift`'s Internals section, delete the line `private let files = FileService()`.

In `FileService.swift`, replace the protocol:

```swift
public protocol FileServicing: Sendable {
    /// List a directory's children. When `includeHidden` is true, filesystem
    /// dotfiles (`.env`, `.claude`, `.gitignore`, …) are revealed; either way the
    /// always-noise names below are filtered.
    func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode]
}
```

and delete the `read(_:)`/`write(_:to:)` method bodies from `struct FileService` (currently `:51-57`).

In `FileSystemCacheTests.swift`, slim the spy:

```swift
private final class CountingFileService: FileServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var enumerateCount: Int { lock.withLock { _count } }

    func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode] {
        lock.withLock { _count += 1 }
        return try FileService().enumerate(directory, includeHidden: includeHidden)
    }
}
```

Delete the file: `git rm Sources/LumeKit/Library/TagSuggest.swift` (recoverable from git history if a prefix-match popover is ever wanted).

- [ ] **Step 2: `xcodegen generate` + run full suite — expect PASS. Grep for `TagSuggest` and stray `files.` in AppState to confirm zero stragglers.**

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove dead code (AppState.files, FileServicing.read/write, TagSuggest)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# Phase 8 — Test gap fills + final verification

### Task 37: LineDiff edge-case tests (pin current contract)

Behavior assessment: `components(separatedBy: "\n")` never returns `[]` — `""` → `[""]` and `"a\n"` → `["a", ""]`. A trailing newline materializes as a final empty line; this is correct/defensible for a line-oriented diff (newline-presence changes are *visible* as an added/removed blank row). These tests pin the contract; **no production change**.

**Files:**
- Test: append to `Tests/LumeKitTests/LineDiffTests.swift`

- [ ] **Step 1: Append the tests**

```swift
// MARK: - Edge cases (audit gap-fill)
// These pin the CURRENT contract of `components(separatedBy: "\n")`: a trailing
// newline yields a final "" line, and "" itself is ONE empty line, never zero.
// Newline-presence changes are therefore visible as an added/removed blank row.

@Test func bothEmptyIsOneSameEmptyLine() {
    let d = LineDiff.compute(from: "", to: "")
    #expect(d == [DiffLine(kind: .same, text: "")])
}

@Test func addingTrailingNewlineShowsAddedEmptyLine() {
    let d = LineDiff.compute(from: "a\nb", to: "a\nb\n")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .same, text: "b"),
        DiffLine(kind: .added, text: ""),
    ])
}

@Test func removingTrailingNewlineShowsRemovedEmptyLine() {
    let d = LineDiff.compute(from: "a\n", to: "a")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: ""),
    ])
}

@Test func identicalTextsWithTrailingNewlineKeepEmptyLastLine() {
    let d = LineDiff.compute(from: "a\n", to: "a\n")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .same, text: ""),
    ])
}

@Test func multiHunkChangesInterleaveInDocumentOrder() {
    // Two separated hunks (line 2 and line 5 change) must come out interleaved
    // with the unchanged middle, each as remove-then-add at its own position.
    let d = LineDiff.compute(from: "a\nb\nc\nd\ne", to: "a\nX\nc\nd\nY")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: "b"),
        DiffLine(kind: .added, text: "X"),
        DiffLine(kind: .same, text: "c"),
        DiffLine(kind: .same, text: "d"),
        DiffLine(kind: .removed, text: "e"),
        DiffLine(kind: .added, text: "Y"),
    ])
}

@Test func emptyOldToMultilineNewReplacesTheEmptyLine() {
    let d = LineDiff.compute(from: "", to: "a\nb")
    #expect(d == [
        DiffLine(kind: .removed, text: ""),
        DiffLine(kind: .added, text: "a"),
        DiffLine(kind: .added, text: "b"),
    ])
}
```

(If any assertion fails, the diff algorithm's actual output differs from the pinned expectation — inspect `LineDiff.compute` and adjust the *expected arrays* to the real, correct output rather than changing the algorithm; flag genuinely wrong behavior back to the user.)

- [ ] **Step 2: Run — expect PASS**

- [ ] **Step 3: Test-hygiene cleanups (audit low findings)**

In `Tests/LumeKitTests/ContextAssemblerTests.swift` and `TokenEstimatorTests.swift`: add `defer { try? FileManager.default.removeItem(at: dir) }` after each temp-dir creation that lacks cleanup (match the pattern already used in ScanEngineTests).

- [ ] **Step 4: Run — expect PASS, then commit**

```bash
git add Tests/LumeKitTests/
git commit -m "test: LineDiff edge cases; temp-dir cleanup hygiene

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 38: Final verification sweep

- [ ] **Step 1: Full clean test run**

```bash
xcodegen generate && xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: **~200 tests, 0 failures** (150 pre-existing minus 2 deleted Bookmark tests, plus ~50 new).

- [ ] **Step 2: Audit cross-check**

Walk `AUDIT.md` finding by finding and confirm each is either fixed by a task above or explicitly deferred (A1, A4, sandbox, render-time enumeration). Mark the audit file accordingly (add a `Status:` line per section or a resolution table at the top).

- [ ] **Step 3: Manual smoke pass (10 min)**

Open a real project folder; browse, expand, rename, trash+undo, tag, note, favorite; run a scan with canonical + overwrite + undo; copy as context (with and without a planted fake secret); open JSON/YAML/TOML/plist/env/HTML/PDF/image files; edit and save a config file and confirm the on-disk diff is minimal and type-faithful.

- [ ] **Step 4: Update project docs**

If `CLAUDE.md` or README mentions removed APIs (Bookmark CRUD, TagSuggest) or the old error behavior, update them.

- [ ] **Step 5: Final commit + merge decision**

Use superpowers:finishing-a-development-branch — present merge/PR options to the user.

---

## Coverage map (AUDIT finding → task)

| Audit finding | Task |
|---|---|
| C1 stale load save corruption | 1, 5 |
| C2 mergeTags prunes empty tags | 14 |
| C3 YAML retypes strings | 27, 28 |
| C4 JSON surrogate pairs | 29 |
| C5 HTMLViewer JS | 22 |
| C6 DirectoryWatcher UAF | 23 |
| A1 AppState god object | **deferred — follow-up plan** |
| A2 try? saves | 13 |
| A3 corrupt store / try! | 16 |
| A3b versioned schema | 10 |
| A4 FileProvider/FileID | **deferred — follow-up plan** |
| Plist data/date + CDATA | 27, 31 |
| TOML dates + number→0 | 27, 30 |
| JSON number grammar + depth | 29 |
| EnvFile CRLF | 32 |
| SecretDetector gaps | 26 |
| Pasteboard concealment | 25 |
| recomputeSyncStatus staleness | 6 |
| overwrite blocking main | 20 |
| watcher main-thread work | 21 |
| ScanTriage/Bundle/Diff stale tasks | 2, 8 |
| NotesPopover cross-write | 7 |
| ⌘Z routing + stale enablement | 35 |
| Second window nukes state | 16 |
| EnvEditor index bindings | 9 |
| moveToTrash stale state | 18 |
| save() blocking main | 19 |
| rename traversal | 3, 17 |
| FileService symlinks | 24 |
| DocumentRouter drift | 33 |
| Shared read API | partially (20 moves overwrite reads into LumeKit); full seam deferred to FileProvider plan |
| Error channel split | 4, 13, 17–20 |
| repointPath on rename | 15, 17 |
| Bookmark dead code | 12 |
| RowSelection.revalidate GROUPS | 34 |
| Dead code (files/read/write/TagSuggest) | 36 |
| Test fixture drift | 11 |
| LineDiff/SecretDetector/watcher/EnvFile test gaps | 23, 26, 32, 37 |
| Temp-dir cleanup, home-dir test | 37 (cleanup); home-dir dependence accepted (documented) |
| Sandbox / Hardened Runtime | deferred (documented trade-off for local builds) |
| FileSystemCache render-time I/O | deferred to FileProvider plan (documented trade-off) |




