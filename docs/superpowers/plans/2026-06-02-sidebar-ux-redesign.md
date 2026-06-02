# Lume Sidebar UX Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse Lume to two panes (Sidebar + Document), fold the Info panel's editing into one unified, navigable, keyboard-driven sidebar, and stop mislabeling Claude Cowork artifacts as broken HTML.

**Architecture:** Pure model/logic changes land in `LumeCore` with Swift Testing unit tests (the `@MainActor` SwiftData test pattern is known-good). SwiftUI view changes land in `LumeApp` and are verified by building and driving the app, since this project has no view-layer unit tests. The sidebar becomes a single `List(selection:)` with three `Section`s — Pinned, Tags, Browser — so native arrow-key selection works, with `DisclosureGroup` expansion and per-row inline editing.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, WebKit, Swift Testing. Spec: `docs/superpowers/specs/2026-06-02-sidebar-ux-redesign-design.md`.

---

## Conventions used throughout this plan

**Build:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
**Test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LumeCoreTests`
**Run (pointed at a folder):**
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LUME_OPEN_FOLDER="$HOME/Documents" swift run LumeApp`

The Xcode toolchain is required — the bare Command Line Tools toolchain lacks the SwiftData macro plugins and the build fails (see prior session). `xcode-select -p` already points at `Xcode.app`, but the env var makes the commands robust regardless of global state.

---

## File Structure

**LumeCore (logic, unit-tested):**
- Modify `Sources/LumeCore/Library/LibraryStore.swift` — add `migrateBookmarksToFavorites()`, `pinnedPaths(taggedWith:)`.
- Create `Sources/LumeCore/Breadcrumb.swift` — pure breadcrumb-segment computation for the path bar.
- Modify `Tests/LumeCoreTests/LibraryStoreTests.swift` — migration + tag-path tests.
- Create `Tests/LumeCoreTests/BreadcrumbTests.swift` — breadcrumb tests.

**LumeApp (views, build-verified):**
- Modify `Sources/LumeApp/AppModel.swift` — drop `sidebarMode`/`showInfoPanel`; add browse/edit state + unified pin/drill actions; wire tag filter; persist `filesOnly` + `browseRoot`.
- Create `Sources/LumeApp/Sidebar/SidebarRow.swift` — the `SidebarRow` row model.
- Rewrite `Sources/LumeApp/Sidebar/SidebarView.swift` — single `List(selection:)`, three sections, breadcrumb header.
- Rewrite `Sources/LumeApp/Sidebar/FileTreeView.swift` — selectable rows, single/double-click, inline rename/tags/notes, context menu.
- Modify `Sources/LumeApp/ContentView.swift` — two-pane split, drop Info toolbar button.
- Delete `Sources/LumeApp/InfoPanel/InfoPanelView.swift`.
- Modify `Sources/LumeApp/LumeApp.swift` — keyboard command menu.
- Modify `Sources/LumeApp/Document/HTMLViewer.swift` — Cowork-artifact detection + native banner.

---

## Task 1: Retire `Bookmark` — migrate bookmarks into pinned folder favorites

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift`
- Test: `Tests/LumeCoreTests/LibraryStoreTests.swift`

Pins unify onto `Favorite`. We keep the `Bookmark` `@Model` type registered in the schema (removing it from the schema is a destructive SwiftData change) but stop creating new bookmarks; a one-time migration converts any existing bookmark into a folder `Favorite`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LumeCoreTests/LibraryStoreTests.swift`:

```swift
@MainActor @Test func migrateBookmarksBecomeFolderFavorites() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.addBookmark(path: "/work")
    store.addBookmark(path: "/docs")
    store.addFavoriteFolder(path: "/work")   // already favorited too

    let migratedCount = store.migrateBookmarksToFavorites()

    // /docs was bookmark-only -> becomes a folder favorite; /work already was.
    #expect(migratedCount == 1)
    #expect(store.isFavorite(path: "/docs") == true)
    #expect(store.favorites().first { $0.path == "/docs" }?.kindRaw == "folder")
    // Bookmarks are cleared after migration so it never runs twice.
    #expect(store.bookmarks().isEmpty)
    // Running again is a no-op.
    #expect(store.migrateBookmarksToFavorites() == 0)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter migrateBookmarksBecomeFolderFavorites`
Expected: FAIL — `value of type 'LibraryStore' has no member 'migrateBookmarksToFavorites'`.

- [ ] **Step 3: Implement the migration**

In `Sources/LumeCore/Library/LibraryStore.swift`, in the `// MARK: Bookmarks` section, add:

```swift
/// One-time migration: every bookmarked folder becomes a folder `Favorite`
/// (pins unify onto Favorites), then the bookmark table is cleared so this is
/// idempotent. Returns how many NEW favorites were created.
@discardableResult
public func migrateBookmarksToFavorites() -> Int {
    let existing = bookmarks()
    var created = 0
    for bm in existing {
        if favorite(for: bm.path) == nil {
            context.insert(Favorite(path: bm.path, kindRaw: "folder",
                                    sortIndex: favorites().count))
            created += 1
        }
        context.delete(bm)
    }
    try? context.save()
    return created
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter migrateBookmarksBecomeFolderFavorites`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/LibraryStoreTests.swift
git commit -m "feat(core): migrate bookmarks into pinned folder favorites (pin unification)"
```

---

## Task 2: Tag → paths helper for filtering the browser

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift`
- Test: `Tests/LumeCoreTests/LibraryStoreTests.swift`

The Browser filters to files matching the active tag. `files(taggedWith:)` already returns `[FileMeta]`; add a thin path-set convenience so the view layer never touches SwiftData models directly.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LumeCoreTests/LibraryStoreTests.swift`:

```swift
@MainActor @Test func pathsTaggedWithReturnsSet() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/a/c.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/a/d.md", info: "", tagNames: ["home"])

    #expect(store.paths(taggedWith: "work") == ["/a/b.md", "/a/c.md"])
    #expect(store.paths(taggedWith: "missing").isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter pathsTaggedWithReturnsSet`
Expected: FAIL — no member `paths(taggedWith:)`.

- [ ] **Step 3: Implement**

In `LibraryStore.swift`, just below `files(taggedWith:)`:

```swift
/// The set of file paths carrying a given tag (for filtering the browser).
public func paths(taggedWith name: String) -> Set<String> {
    Set(files(taggedWith: name).map(\.path))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter pathsTaggedWithReturnsSet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/LibraryStoreTests.swift
git commit -m "feat(core): paths(taggedWith:) convenience for browser tag filtering"
```

---

## Task 3: Breadcrumb segment computation (pure, testable)

**Files:**
- Create: `Sources/LumeCore/Breadcrumb.swift`
- Test: `Tests/LumeCoreTests/BreadcrumbTests.swift`

The path bar shows clickable ancestor segments from a sensible root up to the current folder, substituting `~` for home. Pure value logic, unit-tested, kept out of the view.

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/BreadcrumbTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeCore

@Test func breadcrumbSegmentsUnderHomeUseTilde() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let current = URL(fileURLWithPath: "/Users/manu/Documents/Notes")
    let segs = Breadcrumb.segments(for: current, home: home)

    #expect(segs.map(\.label) == ["~", "Documents", "Notes"])
    #expect(segs.map(\.url.path) ==
        ["/Users/manu", "/Users/manu/Documents", "/Users/manu/Documents/Notes"])
}

@Test func breadcrumbOutsideHomeStartsAtRoot() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let current = URL(fileURLWithPath: "/tmp/work")
    let segs = Breadcrumb.segments(for: current, home: home)

    #expect(segs.map(\.label) == ["/", "tmp", "work"])
}

@Test func breadcrumbAtHomeIsSingleSegment() {
    let home = URL(fileURLWithPath: "/Users/manu")
    let segs = Breadcrumb.segments(for: home, home: home)
    #expect(segs.map(\.label) == ["~"])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter Breadcrumb`
Expected: FAIL — cannot find `Breadcrumb` in scope.

- [ ] **Step 3: Implement**

Create `Sources/LumeCore/Breadcrumb.swift`:

```swift
import Foundation

/// Pure computation of the clickable path-bar segments for the browser.
public enum Breadcrumb {
    public struct Segment: Equatable, Identifiable, Sendable {
        public let label: String
        public let url: URL
        public var id: String { url.path }
    }

    /// Ancestor segments from a root (home shown as `~`, otherwise `/`) up to and
    /// including `current`.
    public static func segments(for current: URL, home: URL) -> [Segment] {
        let cur = current.standardizedFileURL
        let homeStd = home.standardizedFileURL

        // Build the list of path components as URLs, from filesystem root down.
        var urls: [URL] = []
        var walk = cur
        while true {
            urls.append(walk)
            let parent = walk.deletingLastPathComponent()
            if parent.path == walk.path { break }   // reached "/"
            walk = parent
        }
        urls.reverse() // root → current

        // Trim everything above home when current is inside home.
        if cur.path == homeStd.path || cur.path.hasPrefix(homeStd.path + "/") {
            urls = urls.filter { $0.path == homeStd.path || $0.path.hasPrefix(homeStd.path + "/") }
        }

        return urls.map { url in
            let label: String
            if url.path == homeStd.path { label = "~" }
            else if url.path == "/" { label = "/" }
            else { label = url.lastPathComponent }
            return Segment(label: label, url: url)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter Breadcrumb`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Breadcrumb.swift Tests/LumeCoreTests/BreadcrumbTests.swift
git commit -m "feat(core): pure breadcrumb segment computation for the path bar"
```

---

## Task 4: AppModel — new state and actions, drop old modes

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift`

Build-only verification (no view test harness). Removes `SidebarMode`, `sidebarMode`, `showInfoPanel`; adds browser/edit state, unified pin/drill actions, persisted `filesOnly` + `browseRoot`. After this task the app will NOT compile until ContentView/SidebarView are updated (Tasks 5–13); that is expected and the compile is fixed within this sequence. Build at the END of Task 6, not here.

- [ ] **Step 1: Replace the `SidebarMode` enum and state**

In `Sources/LumeApp/AppModel.swift`, delete the `SidebarMode` enum (lines defining `enum SidebarMode...`) entirely. In `AppModel`, remove `var showInfoPanel = true` and `var sidebarMode: SidebarMode = .browse`. Add this state block in their place:

```swift
    // Browser
    var browseRoot: URL? { didSet { persistBrowseRoot() } }
    var filesOnly = false { didSet { UserDefaults.standard.set(filesOnly, forKey: "lume.filesOnly") } }
    var expandedPaths: Set<String> = []
    var selectedRowID: String?

    // Inline editing (which row is mid-edit)
    var renamingPath: String?
    var notesOpenPath: String?
```

- [ ] **Step 2: Add init/persistence for the browser root + filesOnly**

Add to `AppModel` (e.g. just below the stored properties). `AppModel` has no explicit init today, so add one:

```swift
    init() {
        filesOnly = UserDefaults.standard.bool(forKey: "lume.filesOnly")
        if let p = UserDefaults.standard.string(forKey: "lume.browseRoot") {
            browseRoot = URL(fileURLWithPath: p)
        } else {
            browseRoot = FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private func persistBrowseRoot() {
        UserDefaults.standard.set(browseRoot?.path, forKey: "lume.browseRoot")
    }
```

- [ ] **Step 3: Add drill + unified pin actions**

Add to `AppModel`:

```swift
    // MARK: Browser drill navigation

    func drillInto(_ url: URL) {
        browseRoot = url
        expandedPaths.removeAll()
    }

    /// `cd ..` — stops at filesystem root.
    func drillUp() {
        guard let root = browseRoot else { return }
        let parent = root.deletingLastPathComponent()
        if parent.path != root.path { browseRoot = parent }
    }

    // MARK: Pins (unified — a pin IS a favorite, file or folder)

    func isPinned(_ url: URL) -> Bool { isFavorite(url) }

    func togglePin(_ url: URL, isDirectory: Bool) {
        toggleFavorite(url, isDirectory: isDirectory)
    }
```

- [ ] **Step 4: Wire the launch environment + initial browse root**

In `applyLaunchEnvironment()`, after the existing `LUME_OPEN_FOLDER` handling, set the browse root to the opened folder. Replace the `if let folder ...` block with:

```swift
        if let folder = env["LUME_OPEN_FOLDER"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder)
            openFolder(url)
            browseRoot = url
        }
```

- [ ] **Step 5: Commit (compile deferred to Task 6)**

```bash
git add Sources/LumeApp/AppModel.swift
git commit -m "feat(app): AppModel browse/edit state + unified pin/drill, drop sidebar modes"
```

---

## Task 5: SidebarRow model

**Files:**
- Create: `Sources/LumeApp/Sidebar/SidebarRow.swift`

A single identifiable row type backing `List(selection:)`. `id` includes the section so a folder that is both pinned and visible in the browser stays uniquely selectable.

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Which sidebar section a row belongs to (rows of the same path in different
/// sections must stay distinct for `List(selection:)`).
enum SidebarSection: String { case pinned, browser }

/// One selectable row in the unified sidebar.
struct SidebarRow: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var id: String { "\(section.rawValue)|\(url.path)" }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/LumeApp/Sidebar/SidebarRow.swift
git commit -m "feat(app): SidebarRow model for unified List selection"
```

---

## Task 6: Two-pane ContentView + delete Info panel

**Files:**
- Modify: `Sources/LumeApp/ContentView.swift`
- Delete: `Sources/LumeApp/InfoPanel/InfoPanelView.swift`

- [ ] **Step 1: Delete the Info panel file**

```bash
git rm Sources/LumeApp/InfoPanel/InfoPanelView.swift
```

- [ ] **Step 2: Make the detail a single pane**

In `ContentView.swift`, replace the `} detail: { HStack ... }` block (the `HStack` containing `DocumentSurfaceView` and the conditional `InfoPanelView`) with:

```swift
        } detail: {
            DocumentSurfaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
```

- [ ] **Step 3: Remove the Info toolbar button**

In the `.toolbar { ToolbarItemGroup { ... } }`, delete the `Spacer()` and the `Button { withAnimation { model.showInfoPanel.toggle() } } ...` block (the "Info" / `sidebar.trailing` button). Keep Open Folder and Favorite.

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: FAILS only inside `SidebarView.swift`/`FileTreeView.swift` (they still reference `model.sidebarMode`, bookmarks, old rows). ContentView, AppModel, LumeApp.swift must show NO errors. If errors appear outside the sidebar files, fix them before continuing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): two-pane layout — remove Info panel column and toolbar toggle"
```

---

## Task 7: Rewrite SidebarView — single List, three sections, breadcrumb

**Files:**
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift`

Replace the whole file. One `List(selection:)` over three `Section`s. The Browser section's header is the breadcrumb path bar with an up button. Folder rows come from `FileTreeView` (rewritten in Task 8); this task wires structure and the breadcrumb. Tags become clickable filters.

- [ ] **Step 1: Replace the file contents**

```swift
import SwiftUI
import SwiftData
import LumeCore

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.sortIndex) private var favorites: [Favorite]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var allMeta: [FileMeta]

    /// path → custom display name (non-empty only), kept reactive via @Query.
    private var names: [String: String] {
        Dictionary(uniqueKeysWithValues:
            allMeta.filter { !$0.displayName.isEmpty }.map { ($0.path, $0.displayName) })
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedRowID }, set: { model.selectedRowID = $0 })
    }

    var body: some View {
        List(selection: selection) {
            pinnedSection
            if !tags.isEmpty { tagsSection }
            browserSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { filesOnlyBar }
        .onChange(of: model.selectedRowID) { _, id in openIfFile(id) }
    }

    // MARK: Files-only toggle

    private var filesOnlyBar: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.filesOnly },
                                 set: { model.filesOnly = $0 })) {
                Label("Files only", systemImage: "doc")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Pinned

    @ViewBuilder private var pinnedSection: some View {
        Section("Pinned") {
            if favorites.isEmpty {
                Text("Right-click any file or folder to pin it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(favorites) { fav in
                    let url = URL(fileURLWithPath: fav.path)
                    SidebarItemRow(url: url,
                                   isDirectory: fav.kindRaw == "folder",
                                   section: .pinned, depth: 0,
                                   model: model, names: names)
                        .tag(SidebarRow(url: url, isDirectory: fav.kindRaw == "folder",
                                        section: .pinned).id)
                }
                .onMove { indices, newOffset in
                    var paths = favorites.map(\.path)
                    paths.move(fromOffsets: indices, toOffset: newOffset)
                    model.store?.reorderFavorites(paths)
                }
            }
        }
    }

    // MARK: Tags (clickable filters)

    @ViewBuilder private var tagsSection: some View {
        Section("Tags") {
            ForEach(tags) { tag in
                let active = model.activeTagFilter == tag.name
                Label(tag.name, systemImage: active ? "tag.fill" : "tag")
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.activeTagFilter = active ? nil : tag.name
                    }
            }
        }
    }

    // MARK: Browser

    @ViewBuilder private var browserSection: some View {
        Section {
            if let root = model.browseRoot {
                FileTreeView(parent: root, model: model, names: names, depth: 0)
            }
        } header: {
            breadcrumb
        }
    }

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

    // MARK: Selection → open files

    private func openIfFile(_ id: String?) {
        guard let id, let row = decode(id), !row.isDirectory else { return }
        model.selectedFile = row.url
    }

    /// "section|/path" → (url, isDirectory) without needing the source list.
    private func decode(_ id: String) -> (url: URL, isDirectory: Bool)? {
        guard let bar = id.firstIndex(of: "|") else { return nil }
        let path = String(id[id.index(after: bar)...])
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return (url, isDir.boolValue)
    }
}
```

Note: `SidebarItemRow` and `FileTreeView`'s new `init(parent:model:names:depth:)` are defined in Task 8. This file will not compile until Task 8 lands — they are one logical unit; commit at the end of Task 8.

- [ ] **Step 2: Commit (compile completed in Task 8)**

```bash
git add Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "feat(app): unified sidebar — one List with Pinned/Tags/Browser + breadcrumb"
```

---

## Task 8: Rewrite FileTreeView — selectable rows, single/double-click, context menu

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`

Replace the whole file. Provides `SidebarItemRow` (one selectable file/folder row used by both Pinned and Browser) and a `FileTreeView` that lazily lists a parent folder's children, honoring `filesOnly` and the active tag filter. Single-click a folder expands inline; double-click drills in; single-click a file selects it (SidebarView opens it). Inline rename/notes (Tasks 10–11) and chips (Task 11) attach here.

- [ ] **Step 1: Replace the file contents**

```swift
import SwiftUI
import LumeCore

/// Lazily lists the children of `parent`, honoring files-only + tag filter.
struct FileTreeView: View {
    let parent: URL
    let model: AppModel
    var names: [String: String] = [:]
    var depth: Int = 0

    @State private var children: [FileNode] = []

    var body: some View {
        ForEach(visibleChildren) { node in
            SidebarItemRow(url: node.url, isDirectory: node.isDirectory,
                           section: .browser, depth: depth,
                           model: model, names: names)
                .tag(SidebarRow(url: node.url, isDirectory: node.isDirectory,
                                section: .browser).id)

            if node.isDirectory, model.expandedPaths.contains(node.url.path) {
                FileTreeView(parent: node.url, model: model, names: names, depth: depth + 1)
            }
        }
        .onAppear { reload() }
        .onChange(of: parent) { _, _ in reload() }
        .onChange(of: model.filesOnly) { _, _ in /* filter is derived, just refresh view */ }
    }

    private var visibleChildren: [FileNode] {
        var nodes = children
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            // Keep directories (so you can navigate into them) + tagged files.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
        return nodes
    }

    private func reload() {
        children = model.children(of: parent)
    }
}

/// One selectable file/folder row. Single-click a folder toggles inline
/// expansion; double-click drills in. Files select (SidebarView opens them).
struct SidebarItemRow: View {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var depth: Int = 0
    let model: AppModel
    var names: [String: String] = [:]

    private var isExpanded: Bool { model.expandedPaths.contains(url.path) }
    private var isRenaming: Bool { model.renamingPath == url.path }

    var body: some View {
        HStack(spacing: 6) {
            if isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 12)
                    .onTapGesture { toggleExpand() }
            } else {
                Spacer().frame(width: 12)
            }

            if isRenaming {
                RenameField(url: url, model: model)
            } else if isDirectory {
                Label(names[url.path] ?? url.lastPathComponent,
                      systemImage: section == .pinned ? "folder.fill" : "folder")
                    .foregroundStyle(section == .pinned ? .yellow : .primary)
                    .lineLimit(1)
            } else {
                FileRow(url: url,
                        kind: FileKind.detect(filename: url.lastPathComponent),
                        name: names[url.path])
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isDirectory { model.drillInto(url) } }
        .onTapGesture(count: 1) { if isDirectory { toggleExpand() } else { model.selectedFile = url } }
        .contextMenu { RowMenu(url: url, isDirectory: isDirectory, model: model) }
    }

    private func toggleExpand() {
        if isExpanded { model.expandedPaths.remove(url.path) }
        else { model.expandedPaths.insert(url.path) }
    }
}

/// A leaf file row: kind-tinted icon + middle-truncated name.
struct FileRow: View {
    let url: URL
    let kind: FileKind
    var name: String? = nil

    var body: some View {
        Label {
            Text(name ?? url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: icon(for: kind))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(for: kind))
        }
    }

    private func icon(for kind: FileKind) -> String {
        switch kind {
        case .markdown: return "doc.text"
        case .env: return "key.fill"
        case .pdf: return "doc.richtext"
        case .previewable: return "doc"
        case .html: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    private func tint(for kind: FileKind) -> Color {
        switch kind {
        case .markdown: return .blue
        case .env: return .orange
        case .pdf: return .red
        case .html: return .teal
        case .code: return .purple
        case .previewable, .unsupported: return .secondary
        }
    }
}
```

Note: `RenameField` (Task 10) and `RowMenu` (Task 9) are referenced here; they are added in those tasks. Build at the end of Task 10.

- [ ] **Step 2: Commit (compile completed in Task 10)**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): selectable rows, single-click expand, double-click drill-in"
```

---

## Task 9: Right-click context menu

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`

Replaces the old `FavoriteMenu` with `RowMenu`: Open · Drill In · Pin/Unpin · Rename… · Edit Tags… · Reveal in Finder.

- [ ] **Step 1: Add `RowMenu` to the bottom of `FileTreeView.swift`**

```swift
/// Shared right-click menu for any sidebar row.
struct RowMenu: View {
    let url: URL
    let isDirectory: Bool
    let model: AppModel

    var body: some View {
        if isDirectory {
            Button("Open", systemImage: "arrow.right.circle") { model.drillInto(url) }
            Button("Expand / Collapse", systemImage: "chevron.right") { toggleExpand() }
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

    private func toggleExpand() {
        if model.expandedPaths.contains(url.path) { model.expandedPaths.remove(url.path) }
        else { model.expandedPaths.insert(url.path) }
    }
}
```

Add `import AppKit` to the top of `FileTreeView.swift` (for `NSWorkspace`).

- [ ] **Step 2: Commit (compile completed in Task 10)**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): row context menu — open, drill, pin, rename, tags, reveal"
```

---

## Task 10: Inline rename field

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`

`RenameField` edits `FileMeta.displayName` in place; Enter commits, Esc cancels. This is the last piece needed for the sidebar to compile.

- [ ] **Step 1: Add `RenameField` to `FileTreeView.swift`**

```swift
/// In-place display-name editor shown on the row being renamed.
struct RenameField: View {
    let url: URL
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                text = model.store?.displayName(for: url.path) ?? url.lastPathComponent
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { model.renamingPath = nil }   // Esc cancels
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        let store = LibraryStore(context: context)
        let meta = store.meta(for: url.path)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Preserve existing notes/tags; only the display name changes here.
        store.setMeta(path: url.path,
                      info: meta?.info ?? "",
                      tagNames: meta?.tags.map(\.name) ?? [],
                      displayName: trimmed == url.lastPathComponent ? "" : trimmed)
        model.renamingPath = nil
    }
}
```

- [ ] **Step 2: Build the whole app**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS (sidebar now fully defined). Fix any compile errors before continuing.

- [ ] **Step 3: Drive the app and verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LUME_OPEN_FOLDER="$HOME/Documents" swift run LumeApp`
Verify by interaction:
- Single-click a folder in Browser → it expands inline (no triangle hunt).
- Double-click a folder → breadcrumb updates to that folder (drill-in); the up chevron returns.
- Single-click a file → it opens in the right pane.
- Right-click a file → Rename… → type a name, press Enter → the row shows the new display name.
- Right-click a folder → Pin → it appears under Pinned at the top.

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): inline rename field (Enter commits, Esc cancels)"
```

---

## Task 11: Inline tag chips + notes editor on the selected row

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`

When a file row is selected, show its tag chips and a collapsible notes editor beneath it, autosaving (debounced). Replaces everything the old Info panel did.

- [ ] **Step 1: Add an inline metadata view and attach it to selected file rows**

Add to `FileTreeView.swift`:

```swift
/// Tag chips + collapsible notes for the selected file, shown beneath its row.
struct RowMetaView: View {
    let url: URL
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var tagsText = ""
    @State private var notes = ""
    @State private var loaded = false

    private var notesOpen: Bool { model.notesOpenPath == url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField("add tags (comma-separated)", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { save() }
                Button {
                    model.notesOpenPath = notesOpen ? nil : url.path
                } label: {
                    Image(systemName: notesOpen ? "note.text" : "note.text.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Notes")
            }
            if notesOpen {
                TextField("Notes…", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(3...8)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .onChange(of: notes) { _, _ in save() }   // autosave
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, 2)
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in loaded = false; load() }
    }

    private func load() {
        guard !loaded else { return }
        let store = LibraryStore(context: context)
        let meta = store.meta(for: url.path)
        tagsText = meta?.tags.map(\.name).joined(separator: ", ") ?? ""
        notes = meta?.info ?? ""
        loaded = true
    }

    private func save() {
        let store = LibraryStore(context: context)
        let tagNames = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.setMeta(path: url.path, info: notes, tagNames: tagNames,
                      displayName: store.displayName(for: url.path) ?? "")
    }
}
```

- [ ] **Step 2: Show `RowMetaView` under the selected file row**

In `SidebarItemRow.body`, wrap the row in a `VStack` so meta can appear beneath it. Replace the outer `HStack(spacing: 6) { ... }` with:

```swift
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // ... existing row contents unchanged ...
            }
            if !isDirectory, model.selectedFile == url, !isRenaming {
                RowMetaView(url: url, model: model)
            }
        }
```

(Keep all the existing modifiers — `.padding(.leading,...)`, `.contentShape`, `.onTapGesture`, `.contextMenu` — on the `VStack`.)

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS.

- [ ] **Step 4: Drive and verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LUME_OPEN_FOLDER="$HOME/Documents" swift run LumeApp`
Verify:
- Select a file → a tags field appears beneath it. Type `work, draft`, press Enter.
- Click the note button → a notes editor appears; type text. Reselect another file and back → tags/notes persisted.
- Click the "Tags" section's `work` chip → Browser filters to files tagged `work` (folders remain for navigation). Click it again → filter clears.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): inline tag chips + autosaving notes on selected row"
```

---

## Task 12: Keyboard commands

**Files:**
- Modify: `Sources/LumeApp/LumeApp.swift`
- Modify: `Sources/LumeApp/AppModel.swift`

Add menu-backed shortcuts acting on the current selection. Arrow-key row selection and type-select come from `List(selection:)` for free; this task adds the explicit commands. Selection-derived helpers live on `AppModel`.

- [ ] **Step 1: Add selection helpers to `AppModel`**

```swift
    // MARK: Selected-row helpers (for keyboard commands)

    /// The URL of the currently selected row (file or folder), decoded from id.
    var selectedRowURL: URL? {
        guard let id = selectedRowID, let bar = id.firstIndex(of: "|") else { return nil }
        return URL(fileURLWithPath: String(id[id.index(after: bar)...]))
    }

    private var selectedRowIsDirectory: Bool {
        guard let url = selectedRowURL else { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    func renameSelected() { renamingPath = selectedRowURL?.path }

    func pinSelected() {
        guard let url = selectedRowURL else { return }
        togglePin(url, isDirectory: selectedRowIsDirectory)
    }

    func openOrDrillSelected() {
        guard let url = selectedRowURL else { return }
        if selectedRowIsDirectory { drillInto(url) } else { selectedFile = url }
    }
```

- [ ] **Step 2: Add a command menu in `LumeApp.swift`**

In `LumeApp.swift`, the `.commands { ... }` currently only has the Open Folder group. The keyboard commands need to reach the `AppModel`, but `AppModel` is created inside `ContentView`. Use a `FocusedValue` bridge: post notifications the `ContentView` observes (matching the existing `.lumeOpenFolder` pattern). Add these notification names at the top of `LumeApp.swift` next to `lumeOpenFolder`:

```swift
extension Notification.Name {
    static let lumeOpenFolder = Notification.Name("lumeOpenFolder")
    static let lumeRename     = Notification.Name("lumeRename")
    static let lumePin        = Notification.Name("lumePin")
    static let lumeDrillUp    = Notification.Name("lumeDrillUp")
    static let lumeOpenOrDrill = Notification.Name("lumeOpenOrDrill")
}
```

(Remove the now-duplicate single-name extension that exists at the top of the file.)

Then expand the command group:

```swift
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder…") { post(.lumeOpenFolder) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Open / Drill In") { post(.lumeOpenOrDrill) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Go Up") { post(.lumeDrillUp) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Rename") { post(.lumeRename) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Pin / Unpin") { post(.lumePin) }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
```

- [ ] **Step 3: Observe the commands in `ContentView`**

In `ContentView.swift`, after the existing `.onReceive(...for: .lumeOpenFolder)`, add:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .lumeRename)) { _ in model.renameSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .lumePin)) { _ in model.pinSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeDrillUp)) { _ in model.drillUp() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeOpenOrDrill)) { _ in model.openOrDrillSelected() }
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS.

- [ ] **Step 5: Drive and verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LUME_OPEN_FOLDER="$HOME/Documents" swift run LumeApp`
Verify with the sidebar focused (click a row first):
- `↑/↓` move the selection highlight.
- Select a folder, `⌘↑` → drills up (breadcrumb shortens).
- Select a row, `⌘R` → inline rename field appears.
- Select a row, `⌘D` → it pins/unpins (appears/disappears under Pinned).
- Select a folder, `⏎` → drills in; select a file, `⏎` → opens it.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeApp/LumeApp.swift Sources/LumeApp/ContentView.swift Sources/LumeApp/AppModel.swift
git commit -m "feat(app): keyboard commands — rename, pin, drill up/in, open"
```

---

## Task 13: Migrate bookmarks on launch + seed pins

**Files:**
- Modify: `Sources/LumeApp/ContentView.swift`
- Modify: `Sources/LumeApp/AppModel.swift`

Run the Task 1 migration once at launch, and seed default pins for a fresh store (Home, Documents, Desktop, iCloud Drive) as folder favorites instead of bookmarks.

- [ ] **Step 1: Replace `seedDefaultBookmarksIfNeeded` with a pin seeder + migration in `AppModel`**

Replace the `seedDefaultBookmarksIfNeeded()` method body with:

```swift
    /// First-run setup: migrate any old bookmarks to pins, then seed default
    /// pinned locations if there are no favorites yet.
    func seedAndMigratePins() {
        guard let store else { return }
        store.migrateBookmarksToFavorites()
        guard store.favorites().isEmpty else { return }
        let fm = FileManager.default
        store.addFavoriteFolder(path: homeURL.path)
        let candidates = [
            homeURL.appendingPathComponent("Documents"),
            homeURL.appendingPathComponent("Desktop"),
            homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            store.addFavoriteFolder(path: url.path)
        }
    }
```

- [ ] **Step 2: Update the call site in `ContentView.onAppear`**

Replace `model.seedDefaultBookmarksIfNeeded()` with `model.seedAndMigratePins()`.

- [ ] **Step 3: Build + verify migration**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` → PASS.
Run the app. Verify previously-bookmarked folders now appear under **Pinned**, and on a fresh store Home/Documents/Desktop/iCloud appear pinned.

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeApp/AppModel.swift Sources/LumeApp/ContentView.swift
git commit -m "feat(app): migrate bookmarks to pins on launch + seed default pins"
```

---

## Task 14: HTML — detect Cowork artifacts, render with a native banner

**Files:**
- Modify: `Sources/LumeApp/Document/HTMLViewer.swift`

A Cowork artifact contains `<script ... id="cowork-artifact-meta">` and calls `window.cowork.callMcpTool`, which doesn't exist outside Claude — so it shows an in-page error. Detect it and show a clear native banner above the still-rendered HTML.

- [ ] **Step 1: Wrap the web view with a banner-aware container**

Replace the contents of `HTMLViewer.swift`:

```swift
import SwiftUI
import WebKit

/// Read-only web view for `.html`. If the file is a Claude Cowork artifact
/// (needs a live connector bridge that only exists inside Claude), show a
/// native banner explaining why its data won't load — the HTML still renders.
struct HTMLViewer: View {
    let fileURL: URL

    private var isCoworkArtifact: Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return text.contains("id=\"cowork-artifact-meta\"") || text.contains("window.cowork")
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCoworkArtifact {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Claude artifact — needs live connectors, so its data won't load outside Claude.")
                        .font(.callout)
                    Spacer()
                }
                .padding(8)
                .background(.yellow.opacity(0.18))
                Divider()
            }
            WebContent(fileURL: fileURL)
        }
    }
}

/// The underlying `WKWebView` (unchanged behavior).
private struct WebContent: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != fileURL { load(into: view) }
    }

    private func load(into view: WKWebView) {
        let url = fileURL
        ICloudCoordinator.ensureDownloaded(url) { [weak view] in
            view?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS.

- [ ] **Step 3: Verify against the known artifact**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LUME_OPEN_FOLDER="$HOME/Documents/Claude/Artifacts/cara-vfx-setlist" swift run LumeApp`
Select `index.html`. Expected: the yellow native banner appears above the rendered page; a plain self-contained `.html` opened elsewhere shows NO banner.

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeApp/Document/HTMLViewer.swift
git commit -m "feat(app): detect Claude Cowork artifacts and show a native banner"
```

---

## Task 15: Full regression pass

**Files:** none (verification only).

- [ ] **Step 1: Run the LumeCore test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all tests pass (existing + the 4 new ones from Tasks 1–3). The pre-existing `bookmarksAreIndependentOfFavorites` and `reorderBookmarksPersistsOrder` tests still use `addBookmark`/`bookmarks()`, which remain valid (the API isn't deleted, only the app stops calling it) — they should still pass.

- [ ] **Step 2: Full clean build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: PASS with no warnings about unused `SidebarMode`/`InfoPanelView`/`showInfoPanel`.

- [ ] **Step 3: End-to-end drive**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LUME_OPEN_FOLDER="$HOME/Documents" swift run LumeApp`
Walk the full spec: two panes only; one sidebar with Pinned/Tags/Browser; single-click expand; double-click drill; breadcrumb up; files-only toggle; inline rename; inline tags + notes autosave; tag filter; right-click menu; keyboard `↑↓ ⌘↑ ⏎ ⌘R ⌘D`; Cowork banner. Note anything off for a follow-up pass.

- [ ] **Step 4: Final commit (if any cleanup was needed)**

```bash
git add -A
git commit -m "chore: sidebar UX redesign regression pass"
```

---

## Self-Review (completed by plan author)

**Spec coverage:** Two-pane (T6) · unified sidebar/no toggle (T7) · pinned files+folders/merge with bookmarks (T1, T7, T13) · tags as live filters (T2, T7, T11) · breadcrumb + drill `cd ..` (T3, T7, T4) · single-click expand / double-click drill (T8) · files-only toggle (T4, T7, T8) · inline rename (T10) · inline tags + notes autosave (T11) · right-click menu (T9) · keyboard map (T12) · bookmark→pin migration + seed (T1, T13) · Cowork detect-and-label (T14). All spec sections map to tasks.

**Placeholder scan:** No TBD/TODO; every code step shows full code. Cross-file forward references (`SidebarItemRow`, `FileTreeView(parent:…)`, `RenameField`, `RowMenu`, `RowMetaView`) are each defined within Tasks 7–11 and explicitly flagged as "compile completes in Task N" so the engineer isn't surprised by intermediate non-compiling commits.

**Type consistency:** `model.expandedPaths` (Set<String>), `model.selectedRowID` (String?), `SidebarRow.id` ("section|path"), `LibraryStore.paths(taggedWith:)`, `migrateBookmarksToFavorites()`, `Breadcrumb.segments(for:home:)`, `togglePin`/`isPinned`, `drillInto`/`drillUp`, `renamingPath`/`notesOpenPath` are used consistently across tasks.

**Known risk flagged for executor:** SwiftUI `List(selection:)` keyboard behavior with nested recursive `FileTreeView` rows is the highest-uncertainty area. If arrow-key selection doesn't traverse expanded children cleanly, fall back to flattening the browser into a single computed `[SidebarRow]` array fed to one `ForEach` (expansion handled in the model) rather than recursive nesting. This does not change any task's public types.
