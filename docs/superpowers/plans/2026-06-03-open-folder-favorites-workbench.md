# Open Folder & Favorites Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Lume's sidebar into a two-region workbench — a curated multi-select FAVORITES shelf you copy paths from, and an OPEN FOLDER region whose permanent breadcrumb is replaced by a hold-⌃ ancestor path — backed by a per-path Hide flag.

**Architecture:** Pure, unit-tested logic lands in LumeCore (`PathExport`, `FileMeta.hidden`, `LibraryStore` hide API). The app layer (`AppModel`, `SidebarView`, `FileTreeView`, `RowMenu`) consumes it: single-row selection becomes a `Set<String>`, a computed `selectedURLs` feeds every multi-item command, hidden paths filter both regions reactively via the existing `@Query`, and an `NSEvent` `.flagsChanged` monitor drives a transient path bar. No new "working set" model — the selection *is* the set.

**Tech Stack:** Swift 6, SwiftUI (macOS), SwiftData, Swift Testing (`@Test`/`#expect`), Swift Package Manager. Builds require `DEVELOPER_DIR`.

---

## File Structure

**LumeCore (pure, unit-tested):**
- Create `Sources/LumeCore/PathExport.swift` — newline-joined POSIX path export.
- Create `Tests/LumeCoreTests/PathExportTests.swift` — order, joins, single, empty.
- Modify `Sources/LumeCore/Library/Models.swift` — add `FileMeta.hidden`.
- Modify `Sources/LumeCore/Library/LibraryStore.swift` — `setHidden(_:paths:)`, `hiddenPaths()`.
- Modify `Tests/LumeCoreTests/LibraryStoreTests.swift` — hide round-trip + set membership.

**LumeApp:**
- Modify `Sources/LumeApp/AppModel.swift` — `selectedRowIDs: Set<String>`, `selectedURLs`, `showHidden` (persisted), `pathPeek`, `copyPaths()`, `setHidden`/`unhide`, `selectedFolderURLs`.
- Modify `Sources/LumeApp/Sidebar/SidebarView.swift` — `Set` selection binding, retitled sections, "Show hidden" toggle, `hiddenPaths` from `allMeta`, transient ⌃-hold path bar, `.flagsChanged` monitor.
- Modify `Sources/LumeApp/Sidebar/FileTreeView.swift` — hidden filter + dimmed/un-hide affordance, selection-aware `RowMenu`, draggable rows.
- Create `Sources/LumeApp/Sidebar/MultiTagSheet.swift` — apply tags across a multi-selection.
- Create `Sources/LumeApp/Sidebar/ModifierMonitor.swift` — `NSViewRepresentable` `.flagsChanged` monitor.

---

## Task 1: PathExport helper (LumeCore)

**Files:**
- Create: `Sources/LumeCore/PathExport.swift`
- Test: `Tests/LumeCoreTests/PathExportTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/PathExportTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeCore

@Test func pathExportEmptyInputIsEmptyString() {
    #expect(PathExport.clipboardString(for: []) == "")
}

@Test func pathExportSinglePathHasNoTrailingNewline() {
    let url = URL(fileURLWithPath: "/Users/manu/notes.md")
    #expect(PathExport.clipboardString(for: [url]) == "/Users/manu/notes.md")
}

@Test func pathExportJoinsWithNewlinesPreservingOrder() {
    let urls = [
        URL(fileURLWithPath: "/a/z.txt"),
        URL(fileURLWithPath: "/a/m.txt"),
        URL(fileURLWithPath: "/a/b.txt"),
    ]
    #expect(PathExport.clipboardString(for: urls) == "/a/z.txt\n/a/m.txt\n/a/b.txt")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter PathExport`
Expected: FAIL — `cannot find 'PathExport' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LumeCore/PathExport.swift`:

```swift
import Foundation

/// Exports file URLs as the clipboard text an LLM hand-off expects: the absolute
/// POSIX path of each URL, one per line, in the given order (mirrors Finder's
/// "Copy as Pathname"). Empty input yields an empty string.
public enum PathExport {
    public static func clipboardString(for urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter PathExport`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/PathExport.swift Tests/LumeCoreTests/PathExportTests.swift
git commit -m "feat(core): add PathExport.clipboardString for AI path hand-off"
```

---

## Task 2: Add `FileMeta.hidden` field (LumeCore)

**Files:**
- Modify: `Sources/LumeCore/Library/Models.swift:44-58`

SwiftData performs a lightweight automatic migration for an additive property with a default, so no manual migration code is needed. This task has no standalone test (it is exercised by Task 3).

- [ ] **Step 1: Add the property**

In `Sources/LumeCore/Library/Models.swift`, change the `FileMeta` model. Find:

```swift
@Model public final class FileMeta {
    @Attribute(.unique) public var path: String
    public var info: String
    /// Optional user-given label shown instead of the filename (e.g. name a
    /// `.env` "Chief — prod keys" so 10 `.env` files are distinguishable).
    public var displayName: String
    @Relationship(inverse: \Tag.files) public var tags: [Tag]

    public init(path: String, info: String = "", displayName: String = "", tags: [Tag] = []) {
        self.path = path
        self.info = info
        self.displayName = displayName
        self.tags = tags
    }
}
```

Replace with:

```swift
@Model public final class FileMeta {
    @Attribute(.unique) public var path: String
    public var info: String
    /// Optional user-given label shown instead of the filename (e.g. name a
    /// `.env` "Chief — prod keys" so 10 `.env` files are distinguishable).
    public var displayName: String
    /// When true, this path is hidden from both sidebar regions unless the
    /// global "Show hidden" toggle is on. Additive with a default, so SwiftData
    /// migrates existing stores automatically.
    public var hidden: Bool
    @Relationship(inverse: \Tag.files) public var tags: [Tag]

    public init(path: String, info: String = "", displayName: String = "", hidden: Bool = false, tags: [Tag] = []) {
        self.path = path
        self.info = info
        self.displayName = displayName
        self.hidden = hidden
        self.tags = tags
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: Build succeeds (existing `FileMeta(path:)` call sites still compile — every new param has a default).

- [ ] **Step 3: Commit**

```bash
git add Sources/LumeCore/Library/Models.swift
git commit -m "feat(core): add additive FileMeta.hidden flag"
```

---

## Task 3: LibraryStore hide API (LumeCore)

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift` (add two methods near `setMeta`/`meta(for:)`, ~line 125)
- Test: `Tests/LumeCoreTests/LibraryStoreTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/LibraryStoreTests.swift`:

```swift
@MainActor @Test func hideSetsFlagAndHiddenPathsReflectsIt() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    #expect(store.hiddenPaths().isEmpty)

    store.setHidden(true, paths: ["/p/a.txt", "/p/b.txt"])
    #expect(store.hiddenPaths() == ["/p/a.txt", "/p/b.txt"])
    #expect(store.meta(for: "/p/a.txt")?.hidden == true)

    // Un-hiding one path removes only that path from the set.
    store.setHidden(false, paths: ["/p/a.txt"])
    #expect(store.hiddenPaths() == ["/p/b.txt"])
    #expect(store.meta(for: "/p/a.txt")?.hidden == false)
}

@MainActor @Test func hidePreservesExistingMeta() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/p/c.txt", info: "note", tagNames: ["work"], displayName: "C")
    store.setHidden(true, paths: ["/p/c.txt"])

    let m = store.meta(for: "/p/c.txt")
    #expect(m?.hidden == true)
    #expect(m?.info == "note")
    #expect(m?.displayName == "C")
    #expect(m?.tags.map(\.name) == ["work"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter LibraryStore`
Expected: FAIL — `value of type 'LibraryStore' has no member 'setHidden'`.

- [ ] **Step 3: Write the implementation**

In `Sources/LumeCore/Library/LibraryStore.swift`, immediately after the `meta(for:)` method (the block ending around line 131), add:

```swift
    /// Set the hidden flag for each path, upserting `FileMeta` (reusing the
    /// meta-or-insert pattern from `setMeta`) so other metadata is preserved.
    /// Saves once after all paths are updated.
    public func setHidden(_ hidden: Bool, paths: [String]) {
        for path in paths {
            let meta = meta(for: path) ?? {
                let m = FileMeta(path: path)
                context.insert(m)
                return m
            }()
            meta.hidden = hidden
        }
        try? context.save()
    }

    /// All paths currently marked hidden.
    public func hiddenPaths() -> Set<String> {
        let d = FetchDescriptor<FileMeta>(predicate: #Predicate { $0.hidden })
        return Set((try? context.fetch(d))?.map(\.path) ?? [])
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter LibraryStore`
Expected: PASS (all existing + 2 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/LibraryStoreTests.swift
git commit -m "feat(core): add LibraryStore.setHidden and hiddenPaths"
```

---

## Task 4: AppModel — multi-selection, copy, hide, peek (LumeApp)

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift` (properties ~lines 6-33, init ~45-52, helpers near `selectedRowURL` ~203-206, selection handler `openIfFile` ~188-191)

This is an app-layer change with no view-unit-test harness; it is verified by building (this step) and by driving the app in Task 9.

- [ ] **Step 1: Replace single selection with a Set + add new state**

In `Sources/LumeApp/AppModel.swift`, find:

```swift
    var filesOnly = false { didSet { UserDefaults.standard.set(filesOnly, forKey: "lume.filesOnly") } }
    var expandedPaths: Set<String> = []
    var selectedRowID: String?
    var browseFilter: String = ""
```

Replace with:

```swift
    var filesOnly = false { didSet { UserDefaults.standard.set(filesOnly, forKey: "lume.filesOnly") } }
    /// When true, hidden paths are shown (dimmed) instead of omitted.
    var showHidden = false { didSet { UserDefaults.standard.set(showHidden, forKey: "lume.showHidden") } }
    var expandedPaths: Set<String> = []
    /// Multi-row selection for the sidebar `List`. Single-row behaviors
    /// (Quick Look, ←/→, open-on-select) run only when this holds exactly one id.
    var selectedRowIDs: Set<String> = []
    /// True only while ⌃ (Control) is held — drives the transient path bar.
    var pathPeek = false
    var browseFilter: String = ""
```

- [ ] **Step 2: Restore the single-id convenience getter and add selected URL helpers**

Find the existing helper:

```swift
    /// The URL of the currently selected row (file or folder).
    var selectedRowURL: URL? {
        guard let id = selectedRowID else { return nil }
        return SidebarRow.decode(id)?.url
    }
```

Replace with:

```swift
    /// The sole selected row id, or nil when zero or multiple rows are selected.
    /// Single-row keyboard/open behaviors gate on this.
    var soleSelectedRowID: String? {
        selectedRowIDs.count == 1 ? selectedRowIDs.first : nil
    }

    /// The URL of the sole selected row (file or folder), if exactly one.
    var selectedRowURL: URL? {
        guard let id = soleSelectedRowID else { return nil }
        return SidebarRow.decode(id)?.url
    }

    /// All selected rows decoded to file URLs, in sidebar (sorted-id) order.
    /// Every multi-item command consumes this.
    var selectedURLs: [URL] {
        selectedRowIDs.sorted().compactMap { SidebarRow.decode($0)?.url }
    }

    /// Selected rows that are directories, in sidebar order (for Open).
    var selectedFolderURLs: [URL] {
        selectedRowIDs.sorted().compactMap {
            guard let row = SidebarRow.decode($0), row.isDirectory else { return nil }
            return row.url
        }
    }
```

- [ ] **Step 3: Gate the open-on-select handler on a single selection**

Find:

```swift
    private func openIfFile(_ id: String?) {
        guard let id, let row = SidebarRow.decode(id), !row.isDirectory else { return }
        model.selectedFile = row.url
    }
```

Replace with:

```swift
    /// Open a file in the document view only when exactly one file row is
    /// selected, so extending a multi-selection doesn't thrash the document view.
    func openIfSingleFileSelected() {
        guard let id = soleSelectedRowID,
              let row = SidebarRow.decode(id), !row.isDirectory else { return }
        selectedFile = row.url
    }
```

(Note: the original referenced `model.selectedFile`, but inside `AppModel` the receiver is `self`; the corrected body uses `selectedFile` directly. The `.onChange` call site is updated in Task 5.)

- [ ] **Step 4: Add the command methods (copy / hide / open)**

Add these methods to `AppModel` (place them after `drillInto`, ~line 140). `store` is the existing computed `LibraryStore?` accessor used throughout `AppModel` (e.g. in `toggleFavorite`):

```swift
    // MARK: - Multi-selection commands

    /// Write the selected paths to the clipboard as newline-joined POSIX paths
    /// (the AI hand-off) AND as file URLs, so pasting into Finder/editors that
    /// prefer file references also works. Mirrors Finder's "Copy as Pathname".
    func copyPaths() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        pb.setString(PathExport.clipboardString(for: urls), forType: .string)
    }

    /// True when every selected path is already hidden (drives the menu label).
    func selectionIsAllHidden(_ hiddenPaths: Set<String>) -> Bool {
        let urls = selectedURLs
        return !urls.isEmpty && urls.allSatisfy { hiddenPaths.contains($0.path) }
    }

    /// Hide or un-hide every selected path.
    func setHiddenForSelection(_ hidden: Bool) {
        guard let store else { return }
        store.setHidden(hidden, paths: selectedURLs.map(\.path))
    }

    /// Un-hide a single path (inline eye affordance on a dimmed row).
    func unhide(_ url: URL) {
        store?.setHidden(false, paths: [url.path])
    }

    /// Promote the first selected folder to the Open Folder region.
    func openSelectedFolder() {
        guard let folder = selectedFolderURLs.first else { return }
        drillInto(folder)
    }

    /// Remove every selected path from favorites.
    func unpinSelection() {
        guard let store else { return }
        for url in selectedURLs { store.removeFavorite(path: url.path) }
    }
```

- [ ] **Step 5: Initialize `showHidden` from UserDefaults**

Find the init body:

```swift
    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
        if let p = UserDefaults.standard.string(forKey: "lume.browseRoot") {
            browseRoot = URL(fileURLWithPath: p)
        } else {
            browseRoot = FileManager.default.homeDirectoryForCurrentUser
        }
    }
```

Replace with:

```swift
    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
        showHidden = UserDefaults.standard.bool(forKey: "lume.showHidden")
        if let p = UserDefaults.standard.string(forKey: "lume.browseRoot") {
            browseRoot = URL(fileURLWithPath: p)
        } else {
            browseRoot = FileManager.default.homeDirectoryForCurrentUser
        }
    }
```

- [ ] **Step 6: Verify it compiles**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: Build FAILS only in `SidebarView.swift` / `FileTreeView.swift` at the old `selectedRowID` / `openIfFile` references (fixed in Tasks 5-7). `AppModel.swift` itself must compile clean — if errors point inside `AppModel.swift`, fix them before continuing.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumeApp/AppModel.swift
git commit -m "feat(app): AppModel multi-selection, copyPaths, hide, and pathPeek state"
```

---

## Task 5: SidebarView — Set binding, retitled sections, Show-hidden toggle, hidden set

**Files:**
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (selection binding ~21-23, list/sections ~29-35, `.onChange` ~37, top bar ~69-85, derived sets ~14-19)

- [ ] **Step 1: Switch the selection binding to a Set**

Find:

```swift
    private var selection: Binding<String?> {
        Binding(get: { model.selectedRowID }, set: { model.selectedRowID = $0 })
    }
```

Replace with:

```swift
    private var selection: Binding<Set<String>> {
        Binding(get: { model.selectedRowIDs }, set: { model.selectedRowIDs = $0 })
    }
```

- [ ] **Step 2: Update the open-on-select change handler**

Find (around line 37):

```swift
        .onChange(of: model.selectedRowID) { _, id in openIfFile(id) }
```

Replace with:

```swift
        .onChange(of: model.selectedRowIDs) { _, _ in model.openIfSingleFileSelected() }
```

If `openIfFile(_:)` was a private method living in `SidebarView` (not `AppModel`), delete that now-dead method from `SidebarView`. (Per Task 4 the logic now lives in `AppModel.openIfSingleFileSelected()`.)

- [ ] **Step 3: Derive the hidden-paths set from the existing @Query**

Find the `names` computed property:

```swift
    /// path → custom display name (non-empty only), kept reactive via @Query.
    private var names: [String: String] {
        Dictionary(uniqueKeysWithValues:
            allMeta.filter { !$0.displayName.isEmpty }.map { ($0.path, $0.displayName) })
    }
```

Add directly below it:

```swift
    /// Paths flagged hidden, derived reactively from @Query so toggling Hide
    /// updates both regions immediately (same pattern as `names`).
    private var hiddenPaths: Set<String> {
        Set(allMeta.filter { $0.hidden }.map { $0.path })
    }
```

- [ ] **Step 4: Add the "Show hidden" toggle to the top bar**

Find the top bar:

```swift
    private var topBar: some View {
        VStack(spacing: 6) {
            filterField
            HStack {
                Toggle(isOn: Binding(get: { model.filesOnly },
                                     set: { model.filesOnly = $0 })) {
                    Label("Files only", systemImage: "doc")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
```

Replace with:

```swift
    private var topBar: some View {
        VStack(spacing: 6) {
            filterField
            HStack {
                Toggle(isOn: Binding(get: { model.filesOnly },
                                     set: { model.filesOnly = $0 })) {
                    Label("Files only", systemImage: "doc")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Toggle(isOn: Binding(get: { model.showHidden },
                                     set: { model.showHidden = $0 })) {
                    Label("Show hidden", systemImage: "eye.slash")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
```

- [ ] **Step 5: Retitle the sections and thread the hidden set down**

Find the list body and sections:

```swift
    var body: some View {
        List(selection: selection) {
            pinnedSection
            if !tags.isEmpty { tagsSection }
            browserSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { topBar }
```

Add the modifier monitor (from Task 8) by appending `.background(ModifierMonitor(pathPeek: Binding(get: { model.pathPeek }, set: { model.pathPeek = $0 })))` after `.safeAreaInset(...)`. Leave the rest of the chain as-is for now; the monitor type is created in Task 8.

Then retitle the section headers. Locate the `pinnedSection` header text (it currently reads "Pinned" or similar) and change it to `FAVORITES`. Locate the `browserSection` header and change it to include the current folder name:

```swift
    private var openFolderTitle: String {
        let name = model.browseRoot?.lastPathComponent ?? ""
        return name.isEmpty ? "OPEN FOLDER" : "OPEN FOLDER · \(name)"
    }
```

Use `Section(openFolderTitle)` (or `Section(header: Text(openFolderTitle))`, matching the existing header style) for the browser section, and `Section("FAVORITES")` for the pinned section. Pass `hiddenPaths: hiddenPaths` into the `FileTreeView`/`FileRow` calls inside both sections (the parameter is added in Task 6) and into the favorites rows.

> Implementer note: read the actual `pinnedSection` and `browserSection` bodies in this file before editing — match their exact `Section(...)` construction and the existing `FileTreeView(...)` argument lists. Add `hiddenPaths: hiddenPaths` as a new trailing argument to each `FileTreeView` call.

- [ ] **Step 6: Verify it compiles (expect FileTreeView errors only)**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: Remaining failures are in `FileTreeView.swift` (missing `hiddenPaths` parameter) and the not-yet-created `ModifierMonitor` — both fixed in Tasks 6 & 8. `SidebarView.swift`'s own selection/toggle/section code must be error-free.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "feat(app): Set selection binding, retitled regions, Show-hidden toggle"
```

---

## Task 6: FileTreeView — hidden filter, dimmed rows, draggable, selection-aware menu

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (`visibleChildren` ~30-42, `FileRow` ~108-161, `RowMenu` ~164-191, the row body that applies `.contextMenu`)

- [ ] **Step 1: Add the `hiddenPaths` parameter and recurse it**

`FileTreeView` currently takes `parent`, `model`, `names`, `depth`. Add a `hiddenPaths: Set<String>` stored property. Find the recursive call:

```swift
            if node.isDirectory, model.expandedPaths.contains(node.url.path) {
                FileTreeView(parent: node.url, model: model, names: names, depth: depth + 1)
            }
```

Replace with:

```swift
            if node.isDirectory, model.expandedPaths.contains(node.url.path) {
                FileTreeView(parent: node.url, model: model, names: names, hiddenPaths: hiddenPaths, depth: depth + 1)
            }
```

Add `let hiddenPaths: Set<String>` to the struct's stored properties (next to `let names: ...`).

- [ ] **Step 2: Add the hidden filter to `visibleChildren`**

Find:

```swift
    private var visibleChildren: [FileNode] {
        var nodes = children
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            // Keep directories (so you can navigate into them) + tagged files.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }
```

Replace with:

```swift
    private var visibleChildren: [FileNode] {
        var nodes = children
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if !model.showHidden {
            nodes = nodes.filter { !hiddenPaths.contains($0.url.path) }
        }
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            // Keep directories (so you can navigate into them) + tagged files.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }
```

- [ ] **Step 3: Dim hidden rows + inline Un-hide affordance**

In the row body where each `node` is rendered (the `FileRow(...)` call inside the `ForEach` over `visibleChildren`), wrap the row so hidden rows dim and show an eye button. Find the `FileRow(...)` usage and the modifiers attached to that row. Add a computed flag and apply opacity + a trailing eye button. Replace the row's label expression — currently approximately:

```swift
                FileRow(url: node.url, kind: node.kind, name: names[node.url.path])
```

with:

```swift
                HStack {
                    FileRow(url: node.url, kind: node.kind, name: names[node.url.path])
                    if model.showHidden, hiddenPaths.contains(node.url.path) {
                        Spacer(minLength: 0)
                        Button {
                            model.unhide(node.url)
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.borderless)
                        .help("Un-hide")
                    }
                }
                .opacity(hiddenPaths.contains(node.url.path) ? 0.45 : 1)
```

> Implementer note: match the exact existing `FileRow(...)` argument list in this file (it may also pass `autoName:` in the Pinned context). Preserve any existing arguments; only wrap the row and add the eye button.

- [ ] **Step 4: Make rows draggable (path/URL export)**

On the same row, after the existing modifiers (and before/after `.contextMenu`, order doesn't matter), add:

```swift
                .draggable(node.url)
```

`URL` conforms to `Transferable`, so dragging a row carries its file URL (and thus its path when dropped into a text field). Multi-row drag of the whole selection is delivered by AppKit's `List` selection when the dragged row is part of the selection.

- [ ] **Step 5: Make `RowMenu` operate on the selection**

Replace the entire `RowMenu` struct:

```swift
struct RowMenu: View {
    let url: URL
    let isDirectory: Bool
    let model: AppModel

    var body: some View {
        if isDirectory {
            Button("Open", systemImage: "arrow.right.circle") { model.drillInto(url) }
            Button("Expand / Collapse", systemImage: "chevron.right") { model.toggleExpanded(url) }
        } else {
            Button("Open", systemImage: "doc.text") { model.selectedFile = url }
        }
        Divider()
        let pinned = model.isPinned(url)
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
            model.togglePin(url, isDirectory: isDirectory)
        }
        Button("Rename…", systemImage: "pencil") { model.renamingPath = url.path }
        Button("Edit Tags / Notes…", systemImage: "tag") {
            model.selectedFile = url
            model.notesOpenPath = url.path
        }
        Divider()
        Button("Reveal in Finder", systemImage: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
```

with a selection-aware version. It takes the row's id and the derived `hiddenPaths`, ensures the right-clicked row is in the selection (standard macOS fallback), then acts on `model.selectedURLs`:

```swift
struct RowMenu: View {
    let url: URL
    let isDirectory: Bool
    let rowID: String
    let hiddenPaths: Set<String>
    let model: AppModel

    /// Right-clicking a row outside the current selection should act on that one
    /// row (standard macOS behavior): adopt it as the selection first.
    private func ensureSelected() {
        if !model.selectedRowIDs.contains(rowID) {
            model.selectedRowIDs = [rowID]
        }
    }

    private var multi: Bool { model.selectedRowIDs.count > 1 }

    var body: some View {
        Group {
            if isDirectory && !multi {
                Button("Open", systemImage: "arrow.right.circle") {
                    ensureSelected(); model.drillInto(url)
                }
                Button("Expand / Collapse", systemImage: "chevron.right") {
                    model.toggleExpanded(url)
                }
            } else if !multi {
                Button("Open", systemImage: "doc.text") {
                    ensureSelected(); model.selectedFile = url
                }
            }

            Divider()

            Button("Copy Path\(multi ? "s" : "")", systemImage: "doc.on.clipboard") {
                ensureSelected(); model.copyPaths()
            }
            .keyboardShortcut("c", modifiers: [.option, .command])

            let allHidden = model.selectionIsAllHidden(hiddenPaths)
                || (model.selectedRowIDs.isEmpty && hiddenPaths.contains(url.path))
            Button(allHidden ? "Un-hide" : "Hide",
                   systemImage: allHidden ? "eye" : "eye.slash") {
                ensureSelected(); model.setHiddenForSelection(!allHidden)
            }
            .keyboardShortcut(.delete, modifiers: .command)

            Button("Edit Tags…", systemImage: "tag") {
                ensureSelected()
                if multi {
                    model.notesOpenPath = nil
                    model.editingTagsForSelection = true
                } else {
                    model.selectedFile = url
                    model.notesOpenPath = url.path
                }
            }

            if !multi {
                Button("Rename…", systemImage: "pencil") {
                    ensureSelected(); model.renamingPath = url.path
                }
            }

            Button("Unpin", systemImage: "pin.slash") {
                ensureSelected(); model.unpinSelection()
            }

            Divider()

            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                ensureSelected()
                NSWorkspace.shared.activateFileViewerSelecting(model.selectedURLs)
            }
        }
    }
}
```

This adds one new `AppModel` flag, `editingTagsForSelection` (the multi-tag sheet trigger). Add it to `AppModel` properties (Task 4 area) now:

```swift
    /// Drives the multi-selection "Edit Tags…" sheet (see MultiTagSheet).
    var editingTagsForSelection = false
```

- [ ] **Step 6: Update the `.contextMenu` call site**

Find where `RowMenu(...)` is attached (a `.contextMenu { RowMenu(url:..., isDirectory:..., model: model) }`). Update the argument list to pass the new params. It will look like:

```swift
                .contextMenu {
                    RowMenu(url: node.url,
                            isDirectory: node.isDirectory,
                            rowID: SidebarRow(url: node.url, isDirectory: node.isDirectory, section: .browser).id,
                            hiddenPaths: hiddenPaths,
                            model: model)
                }
```

> Implementer note: use the correct `section` for the context — `.browser` inside the browser tree, `.pinned` inside the favorites tree. If `FileTreeView` doesn't already know its section, add a `let section: SidebarSection` stored property to `FileTreeView` and pass `.browser`/`.pinned` from `SidebarView` (Task 5) accordingly, then use `section` here and in the recursive call.

- [ ] **Step 7: Verify it compiles**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: Only the missing `ModifierMonitor` (Task 8) and `MultiTagSheet` (Task 7) remain unresolved. All `FileTreeView`/`RowMenu` code compiles.

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift Sources/LumeApp/AppModel.swift
git commit -m "feat(app): hidden filter, dimmed rows, draggable rows, selection-aware RowMenu"
```

---

## Task 7: Multi-selection tag editor sheet

**Files:**
- Create: `Sources/LumeApp/Sidebar/MultiTagSheet.swift`
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (attach the sheet)
- Modify: `Sources/LumeApp/AppModel.swift` (add `applyTagsToSelection`)

- [ ] **Step 1: Add the apply method to AppModel**

In `AppModel.swift`, add near the other selection commands:

```swift
    /// Apply a comma-separated tag string to every selected path, preserving
    /// each path's existing info/displayName (read via `meta(for:)`).
    func applyTagsToSelection(_ tagString: String) {
        guard let store else { return }
        let names = tagString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for url in selectedURLs {
            let existing = store.meta(for: url.path)
            store.setMeta(path: url.path,
                          info: existing?.info ?? "",
                          tagNames: names,
                          displayName: existing?.displayName ?? "")
        }
    }
```

- [ ] **Step 2: Create the sheet view**

Create `Sources/LumeApp/Sidebar/MultiTagSheet.swift`:

```swift
import SwiftUI

/// A small sheet that applies a comma-separated set of tags to every row in the
/// current multi-selection. The single-row inline editor (RowMetaView) is
/// unchanged; this is the multi-selection path.
struct MultiTagSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var tagText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tags for \(model.selectedURLs.count) items")
                .font(.headline)
            Text("Comma-separated. Applies to every selected item.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. work, prod, review", text: $tagText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.applyTagsToSelection(tagText)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
```

- [ ] **Step 3: Present the sheet from SidebarView**

In `SidebarView.swift`, attach to the `List` (after the existing modifier chain on `body`):

```swift
        .sheet(isPresented: Binding(get: { model.editingTagsForSelection },
                                    set: { model.editingTagsForSelection = $0 })) {
            MultiTagSheet(model: model,
                          isPresented: Binding(get: { model.editingTagsForSelection },
                                               set: { model.editingTagsForSelection = $0 }))
        }
```

- [ ] **Step 4: Verify it compiles**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: Only `ModifierMonitor` (Task 8) remains unresolved.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeApp/Sidebar/MultiTagSheet.swift Sources/LumeApp/Sidebar/SidebarView.swift Sources/LumeApp/AppModel.swift
git commit -m "feat(app): multi-selection Edit Tags sheet"
```

---

## Task 8: Hold-⌃ path bar + modifier monitor (Open Folder)

**Files:**
- Create: `Sources/LumeApp/Sidebar/ModifierMonitor.swift`
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (replace permanent `breadcrumb` header with the transient bar; dim contents during peek)

- [ ] **Step 1: Create the modifier monitor**

Create `Sources/LumeApp/Sidebar/ModifierMonitor.swift`:

```swift
import SwiftUI
import AppKit

/// Observes whether ⌃ (Control) is currently held and writes it to `pathPeek`.
/// A local `.flagsChanged` monitor is the standard AppKit way to track a held
/// modifier. The monitor is removed when the view disappears.
struct ModifierMonitor: NSViewRepresentable {
    @Binding var pathPeek: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            // Hop to the main actor to mutate SwiftUI state safely.
            let control = event.modifierFlags.contains(.control)
            Task { @MainActor in pathPeek = control }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        var monitor: Any?
    }
}
```

- [ ] **Step 2: Confirm the monitor is wired into SidebarView**

In Task 5 Step 5 you appended `.background(ModifierMonitor(pathPeek: ...))` to the `List`. Confirm it is present. If not, add after `.safeAreaInset(edge: .top) { topBar }`:

```swift
        .background(ModifierMonitor(pathPeek: Binding(get: { model.pathPeek },
                                                      set: { model.pathPeek = $0 })))
```

- [ ] **Step 3: Replace the permanent breadcrumb with the transient path bar**

The current Open Folder (browser) section renders the always-on `breadcrumb`. Remove `breadcrumb` from the section header and instead render the transient bar above the folder contents *only while* `model.pathPeek` is true. Replace the `breadcrumb` computed property:

```swift
    private var breadcrumb: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let segs = model.browseRoot.map { Breadcrumb.segments(for: $0, home: home) } ?? []
        return HStack(spacing: 4) {
            Button { model.drillUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .help("Go up (⌘↑)")
            ForEach(Array(segs.enumerated()), id: \.element.id) { i, seg in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(seg.label) { model.drillInto(seg.url) }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .foregroundStyle(i == segs.count - 1 ? .primary : .secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
```

with a transient version:

```swift
    /// Transient ancestor path, shown only while ⌃ is held (model.pathPeek).
    /// Clicking a chip re-roots and the bar collapses; releasing ⌃ collapses it.
    @ViewBuilder private var pathPeekBar: some View {
        if model.pathPeek, let root = model.browseRoot {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let segs = Breadcrumb.segments(for: root, home: home)
            HStack(spacing: 4) {
                ForEach(Array(segs.enumerated()), id: \.element.id) { i, seg in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(seg.label) {
                        model.drillInto(seg.url)   // collapses the bar (pathPeek clears on key-up)
                    }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .foregroundStyle(i == segs.count - 1 ? .primary : .secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }
```

In the browser section, place `pathPeekBar` as the first row, and dim the folder contents while peeking. Inside the `browserSection`, wrap the folder tree with `.opacity(model.pathPeek ? 0.4 : 1)`:

```swift
    private var browserSection: some View {
        Section(openFolderTitle) {
            pathPeekBar
            FileTreeView(parent: model.browseRoot ?? FileManager.default.homeDirectoryForCurrentUser,
                         model: model,
                         names: names,
                         hiddenPaths: hiddenPaths,
                         section: .browser,
                         depth: 0)
                .opacity(model.pathPeek ? 0.4 : 1)
        }
    }
```

> Implementer note: match the existing `browserSection` structure and the exact `FileTreeView(...)` argument list (root param name, etc.). Only add `pathPeekBar`, the new `hiddenPaths:`/`section:` args, and the `.opacity` modifier. Remove any remaining reference to the deleted `breadcrumb` and to `model.drillUp()` if `drillUp` is now unused elsewhere (leave `drillUp` defined; ⌘↑ may still bind to it).

- [ ] **Step 4: Build the whole package**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: Build SUCCEEDS with no errors.

- [ ] **Step 5: Run the full test suite**

Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`
Expected: All tests pass (PathExport + LibraryStore hide tests + all prior tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeApp/Sidebar/ModifierMonitor.swift Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "feat(app): hold-Control transient path bar replacing permanent breadcrumb"
```

---

## Task 9: Build the app & manual verification

**Files:** none (verification only). The app has no view-layer unit tests, so the interactive behaviors are verified by building and driving the app per the spec's Testing section.

- [ ] **Step 1: Build the runnable app bundle**

Run: `./tools/build-app.sh`
Expected: builds `/Applications/Lume.app` (or the script's stated output) with no errors.

- [ ] **Step 2: Launch with a demo folder**

Run (per memory S405 / obs 3985 — the app honors `LUME_OPEN_FOLDER`):

```bash
LUME_OPEN_FOLDER="$HOME/Developer" open -n /Applications/Lume.app
```

- [ ] **Step 3: Verify each acceptance behavior**

Confirm, checking each box only after observing it:

- [ ] Sections read **FAVORITES**, **TAGS** (if any), and **OPEN FOLDER · \<name\>**; no permanent breadcrumb is visible.
- [ ] ⌘-click and ⇧-click select multiple rows in FAVORITES.
- [ ] With several rows selected, right-click → **Copy Paths** (or ⌥⌘C) puts the newline-joined absolute paths on the clipboard (verify with `pbpaste`).
- [ ] Right-click → **Hide** removes a row from both regions; toggling **Show hidden** brings it back dimmed with an eye (Un-hide) button; clicking the eye restores it.
- [ ] Selecting a favorite folder and choosing **Open** promotes it to OPEN FOLDER.
- [ ] Holding **⌃ (Control)** reveals the ancestor path bar (contents dim); clicking an ancestor chip re-roots; releasing ⌃ collapses the bar.
- [ ] **Edit Tags…** on a multi-selection opens the sheet and applies typed tags to all selected paths.
- [ ] Dragging a selected row into a text field (e.g. TextEdit) drops its path/URL.

- [ ] **Step 4: Verify clipboard contents explicitly**

After a multi-select + ⌥⌘C, run: `pbpaste`
Expected: the selected absolute paths, one per line, in sidebar order.

---

## Self-Review (completed during planning)

**Spec coverage:**
- §1 sidebar regions → Task 5 (retitle FAVORITES / OPEN FOLDER·name, remove breadcrumb).
- §2 multi-selection → Task 4 (`selectedRowIDs: Set`, `selectedURLs`, single-row gating) + Task 5 (Set binding).
- §3 row context menu + keyboard → Task 6 (`RowMenu`) with ⌥⌘C, ⌘⌫, Open/Copy/Hide/Edit Tags/Rename/Unpin/Reveal.
- §4 Copy Paths → Task 1 (`PathExport`) + Task 4 (`copyPaths()` string+URLs) + Task 6 (`.draggable`).
- §5 hide/show → Task 2 (`FileMeta.hidden`), Task 3 (`setHidden`/`hiddenPaths`), Task 4 (`showHidden`, wrappers), Task 5 (toggle + derived set), Task 6 (filter + dimmed/un-hide).
- §6 multi-selection tags → Task 7 (`MultiTagSheet`, `applyTagsToSelection`).
- §7 hold-⌃ path reveal → Task 8 (`ModifierMonitor`, `pathPeekBar`, dim).
- Data (§ "Data") → `FileMeta.hidden` (Task 2), `showHidden` UserDefaults `lume.showHidden` (Task 4). ✓ No other schema changes.

**Type consistency:** `selectedRowIDs`/`selectedURLs`/`selectedFolderURLs`, `setHidden(_:paths:)`/`hiddenPaths()`, `PathExport.clipboardString(for:)`, `editingTagsForSelection`, `applyTagsToSelection(_:)`, `pathPeek`/`ModifierMonitor`, `SidebarRow(... ).id` for `rowID` — names match across tasks.

**Open assumptions flagged for the implementer (verify against live source while editing):**
- `AppModel.store` computed `LibraryStore?` accessor exists (used by `toggleFavorite`).
- `LibraryStore.removeFavorite(path:)`, `isPinned`, `toggleExpanded`, `drillUp` exist as used.
- The exact `FileRow(...)`/`FileTreeView(...)` argument lists and `Section(...)` construction — match them verbatim; the plan adds only the new arguments.
