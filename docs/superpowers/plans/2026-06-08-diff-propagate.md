# Diff + Propagate Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Designate one result of a Scan as canonical, see which other copies drift (sync badges + unified DiffView), and overwrite copies with the canonical (confirm + undo). Canonical persists per Scan.

**Architecture:** Pure `LineDiff` engine in LumeKit (stdlib `CollectionDifference`). Canonical persisted as `Scan.canonicalPath`. `AppState` computes a per-result `SyncStatus` cache off-main and performs undoable overwrites via `TextDocument.save()`. Scan triage gains canonical marking, sync badges, a diff preview, and bulk overwrite.

**Tech Stack:** Swift, SwiftUI + AppKit, SwiftData, Swift Testing, XcodeGen project.

---

## Conventions
**Test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -only-testing:LumeKitTests 2>&1 | tail -25`
**Build:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -quiet 2>&1 | tail -25`
New `.swift` files → run `xcodegen generate` before build/test. Native Write/Edit only. Branch: `feat/diff-propagate`. SwiftData test rule: `defer { withExtendedLifetime(container) {} }`.

---

# WAVE A — Logic (LumeKit + model + AppState)

## Task 1: LineDiff engine (TDD)

**Files:**
- Create: `Sources/LumeKit/Document/LineDiff.swift`
- Test: `Tests/LumeKitTests/LineDiffTests.swift`

- [ ] **Step 1: Failing tests**

```swift
// Tests/LumeKitTests/LineDiffTests.swift
import Testing
@testable import LumeKit

@Test func identicalTextsAllSame() {
    let d = LineDiff.compute(from: "a\nb\nc", to: "a\nb\nc")
    #expect(d.allSatisfy { $0.kind == .same })
    #expect(d.map(\.text) == ["a", "b", "c"])
}

@Test func addedLine() {
    let d = LineDiff.compute(from: "a\nc", to: "a\nb\nc")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .added, text: "b"),
        DiffLine(kind: .same, text: "c"),
    ])
}

@Test func removedLine() {
    let d = LineDiff.compute(from: "a\nb\nc", to: "a\nc")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: "b"),
        DiffLine(kind: .same, text: "c"),
    ])
}

@Test func changedLineIsRemoveThenAdd() {
    let d = LineDiff.compute(from: "a\nB\nc", to: "a\nX\nc")
    #expect(d == [
        DiffLine(kind: .same, text: "a"),
        DiffLine(kind: .removed, text: "B"),
        DiffLine(kind: .added, text: "X"),
        DiffLine(kind: .same, text: "c"),
    ])
}

@Test func emptyToOneLineReplacesEmptyLine() {
    let d = LineDiff.compute(from: "", to: "hello")
    #expect(d == [DiffLine(kind: .removed, text: ""), DiffLine(kind: .added, text: "hello")])
}
```

- [ ] **Step 2: Run tests, confirm fail** (after `xcodegen generate`). Run the Test command.

- [ ] **Step 3: Implement**

```swift
// Sources/LumeKit/Document/LineDiff.swift
import Foundation

/// One line of a unified diff.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case same, added, removed }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// Sync state of a copy relative to a canonical file.
public enum SyncStatus: Sendable, Equatable { case canonical, same, differs, unreadable }

/// Pure line-level diff built on the standard-library `CollectionDifference`.
public enum LineDiff {
    /// Unified line diff old→new. `.added` = in new not old; `.removed` = in old not new.
    public static func compute(from old: String, to new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [DiffLine] = []
        var oi = 0, ni = 0
        while oi < oldLines.count || ni < newLines.count {
            if oi < oldLines.count && removed.contains(oi) {
                result.append(DiffLine(kind: .removed, text: oldLines[oi])); oi += 1
            } else if ni < newLines.count && inserted.contains(ni) {
                result.append(DiffLine(kind: .added, text: newLines[ni])); ni += 1
            } else {
                // Unmarked on both sides ⇒ a matched (unchanged) line.
                result.append(DiffLine(kind: .same, text: oldLines[oi])); oi += 1; ni += 1
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests, confirm pass.** Run the Test command.

- [ ] **Step 5: Commit**
```bash
xcodegen generate
git add Sources/LumeKit/Document/LineDiff.swift Tests/LumeKitTests/LineDiffTests.swift
git commit -m "feat: add LineDiff engine and SyncStatus"
```

---

## Task 2: Scan.canonicalPath + LibraryStore.setCanonical (TDD)

**Files:**
- Modify: `Sources/LumeKit/Library/Scan.swift`
- Modify: `Sources/LumeKit/Library/LibraryStore.swift`
- Test: `Tests/LumeKitTests/LibraryStoreScanTests.swift` (append)

- [ ] **Step 1: Failing test** — append to `LibraryStoreScanTests.swift`:

```swift
@MainActor @Test func scanCanonicalPersists() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)

    let s = store.addScan(name: "C", patterns: ["CLAUDE.md"], roots: ["/x"])
    #expect(s.canonicalPath == nil)
    store.setCanonical("/x/CLAUDE.md", for: s)
    #expect(store.scans().first?.canonicalPath == "/x/CLAUDE.md")
    store.setCanonical(nil, for: s)
    #expect(store.scans().first?.canonicalPath == nil)
}
```

- [ ] **Step 2: Run tests, confirm fail** (canonicalPath / setCanonical undefined). Run the Test command.

- [ ] **Step 3: Add the model field.** In `Sources/LumeKit/Library/Scan.swift`:

Add the stored property after `dateAdded`:
```swift
    /// POSIX path of the result chosen as the canonical file to propagate from. nil = none.
    public var canonicalPath: String?
```
Add the parameter to `init` (after `dateAdded: Date = .now`):
```swift
        canonicalPath: String? = nil
```
and in the body:
```swift
        self.canonicalPath = canonicalPath
```
(Optional ⇒ no `@Attribute` default needed; nil is migration-safe.)

- [ ] **Step 4: Add the store method.** In `Sources/LumeKit/Library/LibraryStore.swift`, in the `// MARK: - Scans` section (after `removeScan`):
```swift
    public func setCanonical(_ path: String?, for scan: Scan) {
        scan.canonicalPath = path
        try? context.save()
    }
```

- [ ] **Step 5: Run tests, confirm pass.** Run the Test command.

- [ ] **Step 6: Commit**
```bash
git add Sources/LumeKit/Library/Scan.swift Sources/LumeKit/Library/LibraryStore.swift Tests/LumeKitTests/LibraryStoreScanTests.swift
git commit -m "feat: persist canonical file per Scan"
```

---

## Task 3: AppState — canonical state, sync cache, undoable overwrite

**Files:**
- Modify: `Sources/Lume/AppState.swift`

(No unit test — app-target glue; pure logic is tested in Tasks 1–2. Verify by build.)

- [ ] **Step 1: Add state + derived canonical.** Near the scan/bundle state declarations, add:

```swift
    // MARK: - Propagate (canonical sync) state

    enum OverwriteRequest: Equatable {
        case single(URL)
        case allDiffering([URL])
        var targets: [URL] {
            switch self {
            case .single(let u): return [u]
            case .allDiffering(let us): return us
            }
        }
    }

    /// Staged overwrite awaiting confirmation; non-nil drives the confirm dialog.
    var pendingOverwrite: OverwriteRequest?
    /// Sync state of each active-scan result vs the canonical file (path → status).
    private(set) var syncStatus: [String: SyncStatus] = [:]

    /// The canonical file for the active scan, if one is set.
    var canonicalURL: URL? {
        guard let p = activeScan?.canonicalPath else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Results that differ from the canonical file.
    var differingURLs: [URL] { scanResults.filter { syncStatus[$0.path] == .differs } }
```

- [ ] **Step 2: Add canonical + sync-status methods.** Add (e.g. after the scan methods):

```swift
    // MARK: - Propagate (canonical sync) actions

    func setCanonical(_ url: URL?) {
        guard let library, let activeScan else { return }
        library.setCanonical(url?.path, for: activeScan)
        scans = library.scans()
        Task { await recomputeSyncStatus() }
    }

    /// Recompute each result's sync status vs the canonical file, off-main.
    func recomputeSyncStatus() async {
        guard let canonicalURL else { syncStatus = [:]; return }
        let canonicalPath = canonicalURL.path
        let results = scanResults.map(\.path)
        let computed = await Task.detached(priority: .utility) { () -> [String: SyncStatus] in
            guard let canonText = try? String(contentsOf: URL(fileURLWithPath: canonicalPath), encoding: .utf8) else {
                return [:]   // canonical unreadable ⇒ no anchor
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
        syncStatus = computed
    }

    func requestOverwrite(_ target: URL) { pendingOverwrite = .single(target) }

    func requestOverwriteAllDiffering() {
        let targets = differingURLs
        guard !targets.isEmpty else { return }
        pendingOverwrite = .allDiffering(targets)
    }

    func cancelOverwrite() { pendingOverwrite = nil }

    func confirmOverwrite() {
        defer { pendingOverwrite = nil }
        guard let req = pendingOverwrite, let canonicalURL else { return }
        overwrite(req.targets, withCanonical: canonicalURL)
    }

    /// Overwrite each target with the canonical file's text; registers a single undo.
    private func overwrite(_ targets: [URL], withCanonical canonical: URL) {
        guard let canonText = try? String(contentsOf: canonical, encoding: .utf8) else {
            errorMessage = "Couldn't read the canonical file."
            return
        }
        var restores: [(url: URL, text: String)] = []
        for target in targets where target.path != canonical.path {
            let old = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            do {
                try TextDocument(url: target, text: canonText).save()
                restores.append((target, old))
                cache.invalidate(path: target.deletingLastPathComponent().path)
            } catch {
                errorMessage = "Couldn't overwrite \(target.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if !restores.isEmpty {
            registerUndo("Overwrite with Canonical") { [weak self] in
                for (url, text) in restores {
                    try? TextDocument(url: url, text: text).save()
                    self?.cache.invalidate(path: url.deletingLastPathComponent().path)
                }
                Task { await self?.recomputeSyncStatus() }
            }
        }
        Task { await recomputeSyncStatus() }
    }
```

- [ ] **Step 3: Build, confirm success.** Run the Build command.

- [ ] **Step 4: Commit**
```bash
git add Sources/Lume/AppState.swift
git commit -m "feat: AppState canonical sync status + undoable overwrite"
```

---

# WAVE B — UI (DiffView + Scan triage wiring)

## Task 4: DiffView

**Files:**
- Create: `Sources/Lume/Diff/DiffView.swift`

- [ ] **Step 1: Create the view**

```swift
// Sources/Lume/Diff/DiffView.swift
import SwiftUI
import LumeKit

/// Unified, colored line diff of `canonical` vs `target`, with an overwrite action.
struct DiffView: View {
    @Environment(AppState.self) private var app
    let canonical: URL
    let target: URL

    @State private var lines: [DiffLine] = []
    @State private var unreadable = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if unreadable {
                ContentUnavailableView("Can't Diff", systemImage: "exclamationmark.triangle",
                    description: Text("This file isn't readable as text."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                diffBody
            }
        }
        .task(id: "\(canonical.path)|\(target.path)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
            Text(target.lastPathComponent).font(.headline)
            Text("vs canonical \(canonical.lastPathComponent)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { app.requestOverwrite(target) } label: {
                Label("Overwrite with canonical", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var diffBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(gutter(line.kind)).foregroundStyle(.secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func gutter(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return " "; case .added: return "+"; case .removed: return "-" }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.18)
        }
    }

    private func load() async {
        let c = canonical, t = target
        let computed = await Task.detached(priority: .userInitiated) { () -> [DiffLine]? in
            guard let canonText = try? String(contentsOf: c, encoding: .utf8),
                  let targetText = try? String(contentsOf: t, encoding: .utf8) else { return nil }
            return LineDiff.compute(from: targetText, to: canonText)
        }.value
        if let computed { lines = computed; unreadable = false }
        else { lines = []; unreadable = true }
    }
}
```

> Diff direction: `compute(from: targetText, to: canonText)` so `.added` (green) = what the canonical would add to this copy, `.removed` (red) = what overwriting would drop. Matches the "what will change if I overwrite" mental model.

- [ ] **Step 2: Build** (`xcodegen generate` first — new file). Run the Build command.

- [ ] **Step 3: Commit**
```bash
git add Sources/Lume/Diff/DiffView.swift project.yml
git commit -m "feat: add unified DiffView with overwrite action"
```

---

## Task 5: Scan triage wiring (canonical, badges, diff preview, overwrite)

**Files:**
- Modify: `Sources/Lume/Scans/ScanTriageView.swift`

Read the current file first — it already has Phase 2 additions (`sizes`, `sortBySize`, `displayedResults`, a token badge in each row, a sort button in the header, and the `previewPane`).

- [ ] **Step 1: Drive sync-status recompute.** In `body`, add a `.task` keyed on canonical + results so the cache recomputes when either changes (after the existing `.task(id: app.scanResults)` line):
```swift
        .task(id: "\(app.canonicalURL?.path ?? "none")|\(app.scanResults.map(\.path).joined(separator: "|"))") {
            await app.recomputeSyncStatus()
        }
```

- [ ] **Step 2: Canonical context menu + row styling.** In `fileList`, attach a context menu to the row and reflect canonical state. Replace the row `HStack { … }.tag(url)` content so the name area shows an anchor when canonical, and add a `.contextMenu`. Specifically:

In the `VStack(alignment: .leading, …)` holding the name, change the name `Text(url.lastPathComponent)` line to:
```swift
                        HStack(spacing: 4) {
                            if app.canonicalURL?.path == url.path {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).font(.caption)
                            }
                            Text(url.lastPathComponent).font(.body)
                                .fontWeight(app.canonicalURL?.path == url.path ? .semibold : .regular)
                        }
```
Then add a `.contextMenu` modifier to the row `HStack` (after `.tag(url)`):
```swift
                .contextMenu {
                    if app.canonicalURL?.path == url.path {
                        Button("Clear Canonical") { app.setCanonical(nil) }
                    } else {
                        Button("Set as Canonical") { app.setCanonical(url) }
                    }
                }
```

- [ ] **Step 3: Sync badge replaces token badge when canonical set.** Replace the existing trailing token badge:
```swift
                    Spacer()
                    Text(TokenEstimator.format(sizes[url.path]))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
```
with a conditional badge:
```swift
                    Spacer()
                    if app.canonicalURL != nil {
                        syncBadge(for: url)
                    } else {
                        Text(TokenEstimator.format(sizes[url.path]))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
```
And add this helper method (near `parentLabel`):
```swift
    @ViewBuilder
    private func syncBadge(for url: URL) -> some View {
        switch app.syncStatus[url.path] {
        case .canonical:
            Text("canonical").font(.caption2).foregroundStyle(.tint)
        case .same:
            Label("same", systemImage: "checkmark").labelStyle(.iconOnly)
                .font(.caption).foregroundStyle(.green).help("Matches canonical")
        case .differs:
            Text("Δ").font(.caption).foregroundStyle(.orange).help("Differs from canonical")
        case .unreadable, .none:
            Text("·").font(.caption).foregroundStyle(.tertiary)
        }
    }
```

- [ ] **Step 4: Diff in the preview pane.** In `previewPane`, show a `DiffView` when a canonical is set and the focused file isn't the canonical. Change the body of `previewPane` so it reads:
```swift
    @ViewBuilder
    private var previewPane: some View {
        if let focus = app.scanFocusURL, let canonical = app.canonicalURL, canonical.path != focus.path {
            DiffView(canonical: canonical, target: focus)
        } else if app.scanFocusURL != nil {
            ScrollView {
                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "doc",
                                   description: Text("Pick a file to preview it."))
        }
    }
```

- [ ] **Step 5: Overwrite-all button + confirm dialog.** In `header`, before the `Rescan` button, add an overwrite-all button shown only when something differs:
```swift
            if app.canonicalURL != nil && !app.differingURLs.isEmpty {
                Button { app.requestOverwriteAllDiffering() } label: {
                    Label("Overwrite all differing (\(app.differingURLs.count))", systemImage: "arrow.down.doc.fill")
                }
            }
```
And attach the confirm dialog to the root view. Add to the `HSplitView { … }` chain in `body` (after the `.task` modifiers):
```swift
        .confirmationDialog(
            overwritePrompt,
            isPresented: Binding(
                get: { app.pendingOverwrite != nil },
                set: { if !$0 { app.cancelOverwrite() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) { app.confirmOverwrite() }
            Button("Cancel", role: .cancel) { app.cancelOverwrite() }
        }
```
And add this computed prompt (near the helpers):
```swift
    private var overwritePrompt: String {
        let n = app.pendingOverwrite?.targets.count ?? 0
        return "Overwrite \(n) file\(n == 1 ? "" : "s") with the canonical file? This rewrites \(n == 1 ? "it" : "them") on disk (⌘Z to undo)."
    }
```

- [ ] **Step 6: Build, confirm success.** Run the Build command.

- [ ] **Step 7: Commit**
```bash
git add Sources/Lume/Scans/ScanTriageView.swift
git commit -m "feat: canonical marking, sync badges, diff preview, and overwrite in Scan triage"
```

---

## Task 6: Verify

- [ ] **Step 1: Full suite.** Run the Test command. Expected: all pass (140 + 6 new LineDiff/canonical tests ≈ 146).
- [ ] **Step 2: Build.** Run the Build command. Expected: success.
- [ ] **Step 3: Manual smoke:** run a Scan that gathers ≥2 `CLAUDE.md`; right-click one → **Set as Canonical** (gets the seal + bold); other rows show ✓/Δ badges; focus a differing one → preview shows the colored diff; **Overwrite with canonical** → confirm → the file matches and its badge flips to ✓; ⌘Z restores it; **Overwrite all differing** syncs the rest.

---

## Self-Review Notes
- Spec coverage: LineDiff+SyncStatus (T1), persist canonical (T2), AppState sync cache + undoable overwrite (T3), DiffView (T4), triage canonical/badges/diff/overwrite (T5). All mapped.
- Type consistency: `DiffLine`/`SyncStatus`/`LineDiff.compute`, `Scan.canonicalPath`, `LibraryStore.setCanonical`, `AppState.canonicalURL/setCanonical/recomputeSyncStatus/syncStatus/differingURLs/requestOverwrite/requestOverwriteAllDiffering/confirmOverwrite/cancelOverwrite/pendingOverwrite/OverwriteRequest` used consistently across tasks.
- Off-main: `recomputeSyncStatus` and `DiffView.load` use `Task.detached`. Overwrite writes via `TextDocument.save()` (its own coordinated write); registers a single undo restoring prior contents.
