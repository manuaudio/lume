# Sidebar Click Responsiveness & GROUPS Performance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sidebar clicks instant and correct, and make opening a tag GROUP fast, by removing competing click handlers and stopping the per-toggle disk-tree re-walk.

**Architecture:** Hand single-click selection back to native `List(selection:)` (delete the manual `.onTapGesture` handlers that force a ~250–500ms double-click disambiguation wait); keep only double-click for open/drill. Restore Apple's constant-view-count rule by wrapping each GROUPS tag and each file-tree node in a single child view. Split the row-order computation so a GROUP toggle recomputes only the cheap cache-backed GROUPS slice and never re-walks the favorites/browser disk tree; replace whole-dictionary signature comparisons with a monotonic version counter.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit, SwiftData, Swift Package Manager. Pure logic lives in the `SelectionKit` / `FileSystemKit` frameworks and is unit-tested with Swift Testing in `Tests/LumeCoreTests/`. View/interaction code lives in the `LumeApp` executable target and is verified by a manual run (it has no unit-test surface).

**Source of truth:** This plan implements the audit at `docs/superpowers/2026-06-05-gui-audit-clicks-and-groups-perf.md`.

**Build & run commands (used throughout):**
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
- Test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- Run the GUI app (for manual verification): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-app.sh` then launch the installed Lume.app.

**Baseline:** `swift build` is green with zero warnings (verified 2026-06-05). All `LumeCoreTests` pass.

---

## File Map

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/LumeApp/Sidebar/GroupsSection.swift` | GROUPS region rows | Remove manual single-taps; extract `GroupView` (constant view count) |
| `Sources/LumeApp/Sidebar/FileTreeView.swift` | Favorites/browser tree rows | Remove manual single-tap; extract `FileNodeView` (constant view count) |
| `Sources/LumeApp/Sidebar/SidebarView.swift` | List assembly + flat row-order recompute | Use `GroupRowOrder`; split order signature; version counter; use shared visible-children filter |
| `Sources/LumeApp/AppModel.swift` | App state + selection | Delete dead `clickRow`; add `metaVersion`; cache tree-row-IDs slice |
| `Frameworks/SelectionKit/GroupRowOrder.swift` | **NEW** pure GROUPS row-id ordering | Create + unit-tested |
| `Frameworks/FileSystemKit/VisibleChildrenFilter.swift` | **NEW** pure children visibility filter | Create + unit-tested |
| `Tests/LumeCoreTests/GroupRowOrderTests.swift` | **NEW** tests for `GroupRowOrder` | Create |
| `Tests/LumeCoreTests/VisibleChildrenFilterTests.swift` | **NEW** tests for `VisibleChildrenFilter` | Create |

**Sequencing note:** Tasks are ordered for safe, one-change-at-a-time verification, matching the audit's fix order. Task 2 is a **contingency** — execute it only if Task 1's manual verification shows native single-click is broken. After each task, the human reviewer confirms before the next task starts.

---

## Task 1: Click model — let native selection own single-click

**Why:** Each row stacks native `List(selection:)` + a manual `.onTapGesture(count: 2)` + a manual `.onTapGesture` (single). A single-tap and double-tap recognizer on the same view are mutually exclusive, so SwiftUI delays *every* single click ~250–500ms to disambiguate. That delay is the "clicking does nothing." The manual single-tap also double-writes `selectedRowIDs`, breaking ⌘/⇧. Fix: delete the manual single-tap handlers; keep double-click; let native selection drive single-click. `onChange(of: selectedRowIDs) → openIfSingleFileSelected()` (already wired, `SidebarView.swift:168`) opens a file when it becomes the sole selection, and `SidebarRow.decode` already resolves group-file IDs to real URLs (`SidebarRow.swift:22-33`), so open-on-single-click keeps working through the native path.

**Files:**
- Modify: `Sources/LumeApp/Sidebar/GroupsSection.swift` (group header ~`89-99`, group file row ~`155-166`)
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (`SidebarItemRow` ~`198-208`)
- Modify: `Sources/LumeApp/AppModel.swift` (delete now-dead `clickRow` ~`537-560`)

- [ ] **Step 1: Remove the manual single-tap on the GROUP HEADER row**

In `GroupsSection.swift`, in `groupHeaderRow(_:)`, delete the entire single-tap block (the `.onTapGesture { model.clickRow(...) }` that passes `isDirectory: true` and a bogus `/` URL). Keep the `.onTapGesture(count: 2) { model.toggleGroupExpanded(name) }` immediately above it, and keep the chevron's own `.onTapGesture { model.toggleGroupExpanded(name) }`.

Delete exactly this block (lines ~90-99):

```swift
        // Single-click → SELECT ONLY (honoring ⌘/⇧). A group header has no file to
        // open: passing isDirectory:true routes through clickRow's directory branch
        // (select-only, never sets selectedFile), so the bogus url below is never
        // opened — it exists solely to satisfy the signature.
        .onTapGesture {
            model.clickRow(id: id, isDirectory: true,
                           url: URL(fileURLWithPath: "/"),
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
```

The header keeps its `.tag(id)` and `.contentShape(Rectangle())`, so native `List(selection:)` selects it on mouse-down; double-click still toggles expansion; `openIfSingleFileSelected()` is a no-op for a header id (it decodes to `nil`). Select-only behavior is preserved.

- [ ] **Step 2: Remove the manual single-tap on the GROUP FILE row**

In `GroupsSection.swift`, in `groupFileRow(tagName:path:)`, delete the single-tap block (lines ~159-166):

```swift
        // Single-click → select + open (honoring ⌘/⇧). clickRow decodes the
        // groupfile id to this real file URL via SidebarRow.decode, and because
        // isDirectory:false it sets selectedFile through the normal path.
        .onTapGesture {
            model.clickRow(id: id, isDirectory: false, url: url,
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
```

Keep the `.onTapGesture(count: 2)` above it (double-click opens). Native selection now selects the row; `onChange(selectedRowIDs) → openIfSingleFileSelected()` decodes the group-file id to its real URL and sets `selectedFile`, so single-click still opens.

- [ ] **Step 3: Remove the manual single-tap on the FILE/FOLDER row**

In `FileTreeView.swift`, in `SidebarItemRow.body`, delete the single-tap block (lines ~198-208):

```swift
        // Single click = select + activate (folder → expand inline; file → show
        // content), honoring ⌘/⇧ for multi-select. Native List(selection:) wasn't
        // delivering single clicks to these rows, so this restores the behavior
        // explicitly. Registered AFTER the count:2 gesture so SwiftUI can
        // disambiguate a double-click (drill) from a single click.
        .onTapGesture {
            model.clickRow(id: SidebarRow(url: url, isDirectory: isDirectory, section: section).id,
                           isDirectory: isDirectory, url: url,
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
```

Keep the `.onTapGesture(count: 2)` above it (folder → `drillInto`; file → set selection + `selectedFile`). Keep `.draggableIf`, `.contentShape`, `.contextMenu`, and the chevron's `.onTapGesture { model.toggleExpanded(url) }`.

- [ ] **Step 4: Delete the now-dead `clickRow` from AppModel**

`clickRow` was called only by the three handlers just removed (keyboard navigation uses `RowSelection.move`/`.extend`/`.all` directly, never `clickRow`). In `AppModel.swift` delete the whole method and its doc comment (lines ~537-560), from `/// A mouse click on a sidebar row…` through the closing brace of:

```swift
    func clickRow(id rowID: String, isDirectory: Bool, url: URL,
                  command: Bool, shift: Bool) {
        ...
        if !isDirectory { selectedFile = url }
    }
```

- [ ] **Step 5: Build to confirm no dangling references**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings. If the compiler reports `clickRow` is still referenced somewhere, that call site was missed — find it (`grep -rn "clickRow" Sources`) and remove it before continuing.

- [ ] **Step 6: Run the existing logic tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all `LumeCoreTests` pass (selection/order logic is unchanged; this confirms no regression).

- [ ] **Step 7: Build and run the app for manual verification (GATE)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-app.sh`, then launch the installed Lume.app.

Confirm each, single-clicking ONCE (no pause, no double):
- Single-click a file in OPEN FOLDER → it selects instantly and opens in the document pane. **No perceptible delay.**
- Single-click a favorite file → selects + opens instantly.
- Single-click a folder → selects only (does not expand). Double-click a folder → drills in. Chevron click → expands inline.
- ⌘-click several files → toggles each into/out of the selection. ⇧-click → contiguous range.
- Single-click a GROUP header → selects only (no expand). Double-click header (or chevron) → expands/collapses.
- Expand a group, single-click a file under it → selects + opens instantly.

**Decision gate:**
- ✅ If single-click selects + opens with no delay → Task 1 done. **Skip Task 2.** Proceed to Task 3.
- ❌ If single-click still does nothing / feels shadowed (the old `AppModel.swift` comment warned native delivery "was NOT delivering single clicks") → **proceed to Task 2** (pre-approved AppKit fallback).

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeApp/Sidebar/GroupsSection.swift Sources/LumeApp/Sidebar/FileTreeView.swift Sources/LumeApp/AppModel.swift
git commit -m "fix(sidebar): native single-click selection; drop competing tap handlers

Remove the manual .onTapGesture single handlers on group headers, group
file rows, and file/folder rows. A single-tap + double-tap recognizer on
the same view forced SwiftUI to delay every click ~250-500ms; native
List(selection:) now owns single-click (instant, correct cmd/shift), and
onChange(selectedRowIDs)->openIfSingleFileSelected opens on select.
Delete the now-dead clickRow."
```

---

## Task 2 (CONTINGENCY — only if Task 1 Step 7 failed): AppKit click handler

**Why:** If native `List(selection:)` genuinely does not deliver single-clicks to these rows even after the manual tap is gone, use an AppKit `NSClickGestureRecognizer` overlay. AppKit disambiguates single vs. double natively with **no SwiftUI delay** and guaranteed delivery — the most robust option for a Finder-style browser. This is the audit's pre-approved fallback.

**Skip this entire task if Task 1's manual verification passed.**

**Files:**
- Create: `Sources/LumeApp/Sidebar/ClickCatcher.swift`
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (re-add a delay-free handler), `Sources/LumeApp/Sidebar/GroupsSection.swift` (same), and re-introduce a selection entry point on `AppModel`.

- [ ] **Step 1: Create the AppKit click overlay**

Create `Sources/LumeApp/Sidebar/ClickCatcher.swift`:

```swift
import AppKit
import SwiftUI

/// A transparent overlay that reports single- and double-clicks with the live
/// modifier flags, with NO SwiftUI double-click disambiguation delay. Single
/// and double are separated by AppKit's own click recognizers.
struct ClickCatcher: NSViewRepresentable {
    /// (command, shift) captured at mouse-down time.
    let onSingle: (_ command: Bool, _ shift: Bool) -> Void
    let onDouble: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let single = NSClickGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.single(_:)))
        single.numberOfClicksRequired = 1
        let double = NSClickGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.double(_:)))
        double.numberOfClicksRequired = 2
        single.shouldRequireFailure(of: double)   // single waits only for THIS view's double, not SwiftUI's
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSingle = onSingle
        context.coordinator.onDouble = onDouble
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSingle: onSingle, onDouble: onDouble) }

    final class Coordinator: NSObject {
        var onSingle: (_ command: Bool, _ shift: Bool) -> Void
        var onDouble: () -> Void
        init(onSingle: @escaping (Bool, Bool) -> Void, onDouble: @escaping () -> Void) {
            self.onSingle = onSingle; self.onDouble = onDouble
        }
        @objc func single(_ g: NSClickGestureRecognizer) {
            let f = NSApp.currentEvent?.modifierFlags ?? []
            onSingle(f.contains(.command), f.contains(.shift))
        }
        @objc func double(_ g: NSClickGestureRecognizer) { onDouble() }
    }
}
```

- [ ] **Step 2: Re-introduce a selection entry point on AppModel**

Re-add a single-click handler to `AppModel.swift` (this is the `clickRow` deleted in Task 1, kept only because native delivery failed). Place it near the other selection methods:

```swift
    /// A single mouse click on a sidebar row via the AppKit ClickCatcher overlay
    /// (used only when native List single-click delivery is unavailable). Honors
    /// cmd (toggle) and shift (contiguous range); a plain click sole-selects and,
    /// for a file, opens it.
    func clickRow(id rowID: String, isDirectory: Bool, url: URL,
                  command: Bool, shift: Bool) {
        let r = RowSelection.click(target: rowID, current: selectedRowIDs,
                                   anchor: selectionAnchorID, in: orderedVisibleRowIDs,
                                   command: command, shift: shift)
        selectedRowIDs = r.selection
        selectionAnchorID = r.anchor
        selectionFocusID = r.focus
        guard !command, !shift else { return }
        if !isDirectory { selectedFile = url }
    }
```

- [ ] **Step 3: Attach `ClickCatcher` to the file/folder row**

In `FileTreeView.swift`, in `SidebarItemRow.body`, replace the `.onTapGesture(count: 2)` block with a single `.overlay(ClickCatcher(...))` that handles both clicks (so there is exactly one click pathway, no SwiftUI tap gestures competing):

```swift
        .overlay(ClickCatcher(
            onSingle: { command, shift in
                model.clickRow(id: SidebarRow(url: url, isDirectory: isDirectory, section: section).id,
                               isDirectory: isDirectory, url: url, command: command, shift: shift)
            },
            onDouble: {
                if isDirectory {
                    model.expandedPaths.remove(url.path)
                    model.drillInto(url)
                } else {
                    model.selectedRowIDs = [SidebarRow(url: url, isDirectory: false, section: section).id]
                    model.selectedFile = url
                }
            }))
```

Remove the now-replaced `.onTapGesture(count: 2) { ... }` block. Leave the chevron's own `.onTapGesture { model.toggleExpanded(url) }` (it sits above the overlay and stays hit-testable).

- [ ] **Step 4: Attach `ClickCatcher` to the group header and group file rows**

In `GroupsSection.swift`, in `groupHeaderRow`, replace the `.onTapGesture(count: 2) { model.toggleGroupExpanded(name) }` with:

```swift
        .overlay(ClickCatcher(
            onSingle: { command, shift in
                model.clickRow(id: id, isDirectory: true,
                               url: URL(fileURLWithPath: "/"), command: command, shift: shift)
            },
            onDouble: { model.toggleGroupExpanded(name) }))
```

In `groupFileRow`, replace its `.onTapGesture(count: 2) { ... }` with:

```swift
        .overlay(ClickCatcher(
            onSingle: { command, shift in
                model.clickRow(id: id, isDirectory: false, url: url, command: command, shift: shift)
            },
            onDouble: { model.selectedRowIDs = [id]; model.selectedFile = url }))
```

- [ ] **Step 5: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings.

- [ ] **Step 6: Run the app and re-verify (same checklist as Task 1 Step 7)**

Run: `./build-app.sh`, launch, and confirm single-click selects+opens instantly, double-click drills, ⌘/⇧ multi-select work, group expand works. Single and double clicks must each fire with no perceptible delay.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumeApp/Sidebar/ClickCatcher.swift Sources/LumeApp/Sidebar/FileTreeView.swift Sources/LumeApp/Sidebar/GroupsSection.swift Sources/LumeApp/AppModel.swift
git commit -m "fix(sidebar): AppKit ClickCatcher for delay-free single/double click

Native List single-click was still shadowed; route clicks through an
NSClickGestureRecognizer overlay that disambiguates single vs double with
no SwiftUI delay and guaranteed delivery."
```

---

## Task 3: Constant view count for the GROUPS list — extract `GroupView`

**Why:** `GroupsSection.body` does `ForEach(tags) { tag in groupHeaderRow(tag); if expanded { ForEach(files) { ... } } }` — each element emits 1 view collapsed and 1+N expanded. Apple's List rule requires a **constant** number of views per `ForEach` element; a varying count forces SwiftUI to re-diff the structural identity of the entire `ForEach(tags)` on every expand/collapse. Wrapping each tag in one child view makes the outer `ForEach` a constant 1 view per element.

**Files:**
- Modify: `Sources/LumeApp/Sidebar/GroupsSection.swift`

- [ ] **Step 1: Add a `GroupView` subview that renders header + (conditional) children internally**

In `GroupsSection.swift`, add a new view. It reuses the existing row builders by moving them onto itself — to keep the diff small, make `groupHeaderRow` and `groupFileRow` (and the `icon`/helpers they use) part of `GroupView`. Concretely, add this struct and move the two `@ViewBuilder` row functions plus the `private func icon(forPath:)` into it (cut from `GroupsSection`, paste into `GroupView` unchanged):

```swift
/// One GROUPS element: always renders the header, and renders its file rows
/// only when expanded — but always as a SINGLE child view from the parent
/// ForEach's perspective, satisfying List's constant-view-count rule.
private struct GroupView: View {
    let model: AppModel
    let tag: Tag
    @Binding var renamingTag: TagRef?

    var body: some View {
        let name = tag.name
        groupHeaderRow(tag)
        if model.expandedGroups.contains(name) {
            ForEach(model.sortedGroupFilePaths(forTagNamed: name), id: \.self) { path in
                groupFileRow(tagName: name, path: path)
            }
        }
    }

    // ... groupHeaderRow(_:), groupFileRow(tagName:path:), icon(forPath:) moved here verbatim ...
}
```

> NOTE: `groupHeaderRow` references `renamingTag` (the rename context menu). Pass it in via the `@Binding var renamingTag` shown above so the moved code compiles unchanged.

- [ ] **Step 2: Replace the inline loop body in `GroupsSection` with `GroupView`**

In `GroupsSection.body`, change the `Section` content from:

```swift
            ForEach(tags) { tag in
                groupHeaderRow(tag)
                if model.expandedGroups.contains(tag.name) {
                    ForEach(model.sortedGroupFilePaths(forTagNamed: tag.name), id: \.self) { path in
                        groupFileRow(tagName: tag.name, path: path)
                    }
                }
            }
            newGroupRow
```

to:

```swift
            ForEach(tags) { tag in
                GroupView(model: model, tag: tag, renamingTag: $renamingTag)
            }
            newGroupRow
```

`GroupsSection` keeps `newGroupRow`, the `header`, and the `.alert`. The `showingTagManager` binding stays on `GroupsSection` (the gear button is in the header, not in `GroupView`).

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings. (If `groupHeaderRow`/`groupFileRow`/`icon` are reported as unused on `GroupsSection`, they were moved correctly — delete any leftover copy on `GroupsSection`.)

- [ ] **Step 4: Run the logic tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all pass.

- [ ] **Step 5: Manual verify**

Run `./build-app.sh`, launch. Confirm: groups list renders identically; expanding/collapsing a group is visually smooth (no flicker of unrelated rows); New Group, drag-to-tag, rename, recolor, Copy Paths, delete still work.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeApp/Sidebar/GroupsSection.swift
git commit -m "perf(groups): constant view count via GroupView wrapper

Each tag now emits a single child view from the outer ForEach, so an
expand/collapse no longer re-diffs the whole GROUPS list (Apple's List
constant-view-count rule)."
```

---

## Task 4: Constant view count for the file tree — extract `FileNodeView`

**Why:** `FileTreeView.body` has the same variable-view-count anti-pattern: `ForEach(visibleChildren) { node in SidebarItemRow(...); if node.isDirectory && expanded { FileTreeView(child) } }` — 1 view collapsed, 2 expanded. Wrap each node in a single child view.

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`

- [ ] **Step 1: Add a `FileNodeView` that renders the row + (conditional) recursive subtree**

In `FileTreeView.swift`, add:

```swift
/// One file-tree element: the row, plus — only when it's an expanded folder —
/// its recursive subtree, presented as a SINGLE child view so the parent
/// ForEach keeps a constant view count per element.
private struct FileNodeView: View {
    let node: FileNode
    let model: AppModel
    let section: SidebarSection
    let depth: Int

    var body: some View {
        SidebarItemRow(url: node.url, isDirectory: node.isDirectory,
                       section: section, depth: depth,
                       model: model,
                       displayName: model.displayNames[node.url.path],
                       isHidden: model.hiddenPaths.contains(node.url.path))
            .tag(SidebarRow(url: node.url, isDirectory: node.isDirectory,
                            section: section).id)

        if node.isDirectory, model.expandedPaths.contains(node.url.path) {
            FileTreeView(parent: node.url, model: model,
                         section: section, depth: depth + 1)
        }
    }
}
```

- [ ] **Step 2: Use `FileNodeView` in `FileTreeView.body`**

Replace the `ForEach(visibleChildren)` body. Change:

```swift
        ForEach(visibleChildren) { node in
            SidebarItemRow(url: node.url, isDirectory: node.isDirectory,
                           section: section, depth: depth,
                           model: model,
                           displayName: model.displayNames[node.url.path],
                           isHidden: model.hiddenPaths.contains(node.url.path))
                .tag(SidebarRow(url: node.url, isDirectory: node.isDirectory,
                                section: section).id)

            if node.isDirectory, model.expandedPaths.contains(node.url.path) {
                FileTreeView(parent: node.url, model: model,
                             section: section, depth: depth + 1)
            }
        }
        .onAppear { reload() }
```

to:

```swift
        ForEach(visibleChildren) { node in
            FileNodeView(node: node, model: model, section: section, depth: depth)
        }
        .onAppear { reload() }
```

Keep all the `.onChange(...)` modifiers and `reload()` exactly as-is — they belong to this `FileTreeView` (this directory's enumeration), not to the per-node child.

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings.

- [ ] **Step 4: Run the logic tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all pass.

- [ ] **Step 5: Manual verify**

Run `./build-app.sh`, launch. Confirm: the favorites tree and browser tree render identically; expanding/collapsing a folder (chevron and double-click) works; nested folders still expand; FSEvents refresh (edit a file in Finder) still updates the right directory; the filter field still narrows the tree.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "perf(tree): constant view count via FileNodeView wrapper

Each node emits a single child view, so expanding a folder no longer
re-diffs the whole sibling list."
```

---

## Task 5: Extract a pure, cache-only GROUPS row-order function (TDD)

**Why:** `SidebarView.computeOrderedRowIDs()` builds the flat keyboard-order list by (a) iterating the GROUPS cache and (b) recursively walking the favorites/browser disk tree. The GROUPS portion is cheap and cache-only; the tree portion is the expensive `FileManager` walk. To stop a GROUP toggle from triggering the disk walk (Task 6), first extract the GROUPS portion into a pure, unit-tested function in `SelectionKit`. It mirrors `SidebarView.swift:55-61` exactly.

**Files:**
- Create: `Frameworks/SelectionKit/GroupRowOrder.swift`
- Create: `Tests/LumeCoreTests/GroupRowOrderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/GroupRowOrderTests.swift`:

```swift
import Testing
import SelectionKit

@Suite("GroupRowOrder")
struct GroupRowOrderTests {
    @Test("collapsed groups emit only header ids, in tagName order")
    func collapsedHeadersOnly() {
        let ids = GroupRowOrder.ids(
            tagNames: ["alpha", "beta"],
            expandedGroups: [],
            groupFilePaths: ["alpha": ["/a.md"], "beta": ["/b.md"]])
        #expect(ids == [
            GroupRowID.headerID(tagName: "alpha"),
            GroupRowID.headerID(tagName: "beta"),
        ])
    }

    @Test("an expanded group emits its header then one file id per cached path, in cache order")
    func expandedGroupEmitsFiles() {
        let ids = GroupRowOrder.ids(
            tagNames: ["alpha"],
            expandedGroups: ["alpha"],
            groupFilePaths: ["alpha": ["/z.md", "/a.md"]])   // cache order preserved (not re-sorted)
        #expect(ids == [
            GroupRowID.headerID(tagName: "alpha"),
            GroupRowID.fileID(tagName: "alpha", path: "/z.md"),
            GroupRowID.fileID(tagName: "alpha", path: "/a.md"),
        ])
    }

    @Test("an expanded group with no cached members emits only its header")
    func expandedEmptyGroup() {
        let ids = GroupRowOrder.ids(
            tagNames: ["empty"],
            expandedGroups: ["empty"],
            groupFilePaths: ["empty": []])
        #expect(ids == [GroupRowID.headerID(tagName: "empty")])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GroupRowOrder`
Expected: FAIL to compile — "cannot find 'GroupRowOrder' in scope".

- [ ] **Step 3: Write the minimal implementation**

Create `Frameworks/SelectionKit/GroupRowOrder.swift`:

```swift
import Foundation

/// Pure, cache-only ordering of the GROUPS region's flat row ids: each tag's
/// header, followed (when that group is expanded) by one file-row id per cached
/// member path, in cache order. No disk access. Mirrors the GROUPS loop that the
/// sidebar's keyboard-order walk used to inline, so render order and keyboard
/// order share one definition.
public enum GroupRowOrder {
    public static func ids(tagNames: [String],
                           expandedGroups: Set<String>,
                           groupFilePaths: [String: [String]]) -> [String] {
        var ids: [String] = []
        for name in tagNames {
            ids.append(GroupRowID.headerID(tagName: name))
            guard expandedGroups.contains(name) else { continue }
            for path in groupFilePaths[name] ?? [] {
                ids.append(GroupRowID.fileID(tagName: name, path: path))
            }
        }
        return ids
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GroupRowOrder`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Frameworks/SelectionKit/GroupRowOrder.swift Tests/LumeCoreTests/GroupRowOrderTests.swift
git commit -m "feat(selectionkit): pure GroupRowOrder.ids for cache-only GROUPS ordering"
```

---

## Task 6: Split the order recompute so a GROUP toggle never walks the disk tree

**Why:** `rowOrderSignature` folds *every* order input (GROUPS state + favorites + browser + whole dicts) into one value; any change — including a GROUP expand — re-runs `computeOrderedRowIDs()`, which recursively walks the entire favorites + browser disk tree via `model.children(of:)`. Toggling one cache-backed group should not re-read unrelated directories. Fix: keep the expensive **tree** slice cached and recompute it only when *tree* inputs change; recompute the cheap **GROUPS** slice (via `GroupRowOrder.ids`) whenever GROUPS inputs change; combine the two for `orderedVisibleRowIDs`.

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift` (cache the tree slice)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (split signatures + recompute paths)

- [ ] **Step 1: Add a cached tree-slice store on AppModel**

In `AppModel.swift`, next to `orderedVisibleRowIDs` (line ~109), add:

```swift
    /// The favorites+browser portion of the flat visible order, cached so a
    /// GROUPS toggle (cheap, cache-only) doesn't trigger the expensive disk-tree
    /// walk. Recomputed only when tree structure/visibility changes.
    @ObservationIgnored var treeRowIDs: [String] = []
```

- [ ] **Step 2: Split `computeOrderedRowIDs` into a GROUPS part and a tree part in SidebarView**

In `SidebarView.swift`, import is already `SelectionKit`-aware via the row types. Replace `computeOrderedRowIDs()` (lines ~49-83) with two functions — one cheap GROUPS slice (delegating to `GroupRowOrder`) and one tree slice (the existing disk walk, GROUPS loop removed):

```swift
    /// Cheap, cache-only GROUPS slice (no disk access).
    private func groupRowIDs() -> [String] {
        GroupRowOrder.ids(tagNames: tags.map(\.name),
                          expandedGroups: model.expandedGroups,
                          groupFilePaths: model.groupFilePaths)
    }

    /// Expensive favorites + browser slice: recursively walks the expanded tree
    /// via `model.children(of:)` (an uncached FileManager read per expanded
    /// folder). Recomputed ONLY when `treeOrderSignature` changes — never on a
    /// GROUP toggle or a selection change.
    private func computeTreeRowIDs() -> [String] {
        var ids: [String] = []

        func walk(_ url: URL, isDir: Bool, section: SidebarSection, includeHidden: Bool) {
            ids.append(SidebarRow(url: url, isDirectory: isDir, section: section).id)
            guard isDir, model.expandedPaths.contains(url.path) else { return }
            for child in visibleChildren(of: url, section: section, includeHidden: includeHidden) {
                walk(child.url, isDir: child.isDirectory, section: section, includeHidden: includeHidden)
            }
        }

        for fav in visibleFavorites {
            walk(URL(fileURLWithPath: fav.path), isDir: fav.kindRaw == "folder",
                 section: .pinned, includeHidden: false)
        }
        if let root = model.browseRoot {
            for child in visibleChildren(of: root, section: .browser,
                                         includeHidden: model.showBrowserHidden) {
                walk(child.url, isDir: child.isDirectory, section: .browser,
                     includeHidden: model.showBrowserHidden)
            }
        }
        return ids
    }
```

- [ ] **Step 3: Replace the single signature with two signatures**

In `SidebarView.swift`, replace `rowOrderSignature` (lines ~94-109) with two computed signatures. The GROUPS signature covers only GROUPS inputs; the tree signature covers only favorites/browser inputs:

```swift
    /// GROUPS-only order inputs (cheap). A change here recomputes only the
    /// cache-backed GROUPS slice — no disk walk.
    private var groupOrderSignature: GroupOrderSignature {
        GroupOrderSignature(
            expandedGroups: model.expandedGroups,
            tagNames: tags.map(\.name),
            groupFilePaths: model.groupFilePaths)
    }

    /// Favorites + browser order inputs (expensive). Only a change here re-runs
    /// the recursive disk walk.
    private var treeOrderSignature: TreeOrderSignature {
        TreeOrderSignature(
            expanded: model.expandedPaths,
            browseRoot: model.browseRoot?.path,
            favoritePaths: visibleFavorites.map(\.path),
            filesOnly: model.filesOnly,
            browseFilter: model.browseFilter,
            showBrowserHidden: model.showBrowserHidden,
            showPinnedHidden: model.showPinnedHidden,
            hiddenPaths: model.hiddenPaths)
    }
```

> NOTE: `displayNames` is intentionally dropped from the tree signature — display-name changes affect GROUPS *file ordering* (handled by `groupFilePaths`, which `MetaIndexLoader` re-sorts on a name change) and per-row labels (handled reactively by the row's scalar), not the favorites/browser *structure*. This removes a whole-dictionary comparison from the hot path. `groupFilePaths` is replaced by a version counter in Task 7.

- [ ] **Step 4: Replace the `RowOrderSignature` struct with the two new structs**

In `SidebarView.swift`, replace the `private struct RowOrderSignature` (lines ~467-484) with:

```swift
private struct GroupOrderSignature: Equatable {
    let expandedGroups: Set<String>
    let tagNames: [String]
    let groupFilePaths: [String: [String]]   // replaced by a version counter in Task 7
}

private struct TreeOrderSignature: Equatable {
    let expanded: Set<String>
    let browseRoot: String?
    let favoritePaths: [String]
    let filesOnly: Bool
    let browseFilter: String
    let showBrowserHidden: Bool
    let showPinnedHidden: Bool
    let hiddenPaths: Set<String>
}
```

- [ ] **Step 5: Rewire the recompute `.onChange`/`.onAppear` handlers**

In `SidebarView.body`, replace the single `.onChange(of: rowOrderSignature)` and the `.onAppear` recompute (lines ~173-178) with three handlers: GROUPS-only recompute (cheap), tree recompute (expensive), and initial build:

```swift
        // GROUP toggles, tag membership, tag list changes → recompute the cheap
        // cache-only GROUPS slice and recombine. No disk walk.
        .onChange(of: groupOrderSignature) { _, _ in
            model.orderedVisibleRowIDs = groupRowIDs() + model.treeRowIDs
        }
        // Favorites/browser structure changes → re-run the recursive disk walk,
        // cache it, recombine.
        .onChange(of: treeOrderSignature) { _, _ in
            model.treeRowIDs = computeTreeRowIDs()
            model.orderedVisibleRowIDs = groupRowIDs() + model.treeRowIDs
        }
        .onAppear {
            model.treeRowIDs = computeTreeRowIDs()
            model.orderedVisibleRowIDs = groupRowIDs() + model.treeRowIDs
        }
```

- [ ] **Step 6: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings.

- [ ] **Step 7: Run the logic tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all pass (selection/order math unchanged; `orderedVisibleRowIDs` is assembled to the same value, just computed in two slices).

- [ ] **Step 8: Manual verify (GATE — this is the "slow expand" fix)**

Run `./build-app.sh`, launch. With several favorites pinned and a large folder open & expanded:
- Expand/collapse a GROUP repeatedly → **fast**, no stutter, no main-thread hang. (Previously each toggle re-walked the whole favorites+browser tree.)
- Keyboard order still correct across regions: ↑/↓ traverse GROUPS → FAVORITES → OPEN FOLDER in visible order; ⇧↑/⇧↓ extend; ⌘A selects all; → expands a folder; ← collapses/jumps to parent.
- Tagging/untagging a file updates its group's contents and order; renaming a file re-sorts its group rows.
- Expanding a favorites/browser folder still updates the flat order (arrow keys reach the newly revealed children).

- [ ] **Step 9: Commit**

```bash
git add Sources/LumeApp/AppModel.swift Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "perf(sidebar): split order recompute so GROUP toggles skip the disk walk

GROUPS order is now a cheap cache-only slice (GroupRowOrder.ids) recomputed
on a GROUPS-only signature; the favorites/browser slice is cached and
re-walked only when tree structure changes. Toggling a group no longer
triggers a recursive FileManager walk of unrelated favorites/browser trees."
```

---

## Task 7: Replace whole-dictionary signature compares with a version counter

**Why:** `GroupOrderSignature` still deep-copies and `==`-compares the whole `groupFilePaths` dictionary on every body pass — itself O(n). `MetaIndexLoader` is the *only* writer of `groupFilePaths` (and `displayNames`/`hiddenPaths`); bump a monotonic counter there and compare the cheap `Int` instead.

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift` (add `metaVersion`, bump in the meta writers)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (`GroupOrderSignature` uses the counter)

- [ ] **Step 1: Add a `metaVersion` counter bumped by the meta writers**

In `AppModel.swift`, add near `groupFilePaths` (line ~818):

```swift
    /// Monotonic version of the meta index (displayNames / hiddenPaths /
    /// groupFilePaths). Bumped only when one of those actually changes, so order
    /// signatures can compare a cheap Int instead of whole dictionaries.
    @ObservationIgnored private(set) var metaVersion: Int = 0
```

In `updateGroupFilePaths(_:)` (line ~821), bump on real change:

```swift
    func updateGroupFilePaths(_ map: [String: [String]]) {
        if groupFilePaths != map { groupFilePaths = map; metaVersion &+= 1 }
    }
```

Find `updateMetaIndex(displayNames:hiddenPaths:)` (called by `MetaIndexLoader.push()`) and bump it there too when either input changes. Locate it (`grep -n "func updateMetaIndex" Sources/LumeApp/AppModel.swift`) and apply:

```swift
    func updateMetaIndex(displayNames: [String: String], hiddenPaths: Set<String>) {
        if self.displayNames != displayNames { self.displayNames = displayNames; metaVersion &+= 1 }
        if self.hiddenPaths != hiddenPaths { self.hiddenPaths = hiddenPaths; metaVersion &+= 1 }
    }
```

> If `updateMetaIndex` currently assigns unconditionally, wrap each assignment in the `if … != …` guard shown above so the counter only advances on real change (and so unchanged meta doesn't re-trigger order recompute).

- [ ] **Step 2: Use `metaVersion` in `GroupOrderSignature`**

In `SidebarView.swift`, change `groupOrderSignature` to read the counter instead of the dict:

```swift
    private var groupOrderSignature: GroupOrderSignature {
        GroupOrderSignature(
            expandedGroups: model.expandedGroups,
            tagNames: tags.map(\.name),
            metaVersion: model.metaVersion)
    }
```

And change the struct:

```swift
private struct GroupOrderSignature: Equatable {
    let expandedGroups: Set<String>
    let tagNames: [String]
    let metaVersion: Int
}
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings.

- [ ] **Step 4: Run the logic tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all pass.

- [ ] **Step 5: Manual verify**

Run `./build-app.sh`, launch. Confirm GROUPS still re-order correctly on the meta-driven changes that bump the counter: tag/untag a file (membership changes), rename a file in a group (re-sorts), hide/unhide. Expand speed remains fast.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeApp/AppModel.swift Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "perf(sidebar): version counter instead of whole-dict order signature

MetaIndexLoader bumps metaVersion when displayNames/hiddenPaths/groupFilePaths
change; the GROUPS order signature compares that Int instead of deep-copying
and equating the whole groupFilePaths dictionary each body pass."
```

---

## Task 8: Cleanup — one shared visible-children filter (TDD)

**Why:** The children-visibility filter is duplicated in `FileTreeView.visibleChildren` and `SidebarView.visibleChildren(of:section:includeHidden:)` and flagged in-code as "⚠️ CROSS-PHASE DRIFT" — two copies that must stay in lockstep. Hoist the pure filtering into one unit-tested helper in `FileSystemKit` (where `FileNode` lives), and call it from both sites.

**Files:**
- Create: `Frameworks/FileSystemKit/VisibleChildrenFilter.swift`
- Create: `Tests/LumeCoreTests/VisibleChildrenFilterTests.swift`
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift`, `Sources/LumeApp/Sidebar/SidebarView.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/VisibleChildrenFilterTests.swift`. (Adjust the `FileNode` initializer in the helper below to match its real signature — confirm with `grep -n "init" Frameworks/FileSystemKit/FileNode.swift`; this test assumes `FileNode(url:isDirectory:)` and a `name` derived from the last path component.)

```swift
import Foundation
import Testing
import FileSystemKit

@Suite("VisibleChildrenFilter")
struct VisibleChildrenFilterTests {
    private func node(_ path: String, dir: Bool = false) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path), isDirectory: dir)
    }

    @Test("filesOnly drops directories")
    func filesOnly() {
        let out = VisibleChildrenFilter.apply(
            [node("/a.md"), node("/sub", dir: true)],
            filesOnly: true, isPinned: false,
            showPinnedHidden: false, hiddenPaths: [], browseFilter: "")
        #expect(out.map(\.url.path) == ["/a.md"])
    }

    @Test("pinned section hides hidden paths unless reveal is on")
    func pinnedHidden() {
        let nodes = [node("/keep.md"), node("/secret.md")]
        let hidden: Set<String> = ["/secret.md"]
        let off = VisibleChildrenFilter.apply(nodes, filesOnly: false, isPinned: true,
                                              showPinnedHidden: false, hiddenPaths: hidden, browseFilter: "")
        #expect(off.map(\.url.path) == ["/keep.md"])
        let on = VisibleChildrenFilter.apply(nodes, filesOnly: false, isPinned: true,
                                             showPinnedHidden: true, hiddenPaths: hidden, browseFilter: "")
        #expect(on.map(\.url.path) == ["/keep.md", "/secret.md"])
    }

    @Test("browser section never applies the pinned-hidden filter")
    func browserIgnoresHidden() {
        let out = VisibleChildrenFilter.apply(
            [node("/keep.md"), node("/secret.md")],
            filesOnly: false, isPinned: false,
            showPinnedHidden: false, hiddenPaths: ["/secret.md"], browseFilter: "")
        #expect(out.map(\.url.path) == ["/keep.md", "/secret.md"])
    }

    @Test("text filter keeps directories and case-insensitive name matches")
    func textFilter() {
        let out = VisibleChildrenFilter.apply(
            [node("/Notes.md"), node("/todo.txt"), node("/dir", dir: true)],
            filesOnly: false, isPinned: false,
            showPinnedHidden: false, hiddenPaths: [], browseFilter: "note")
        #expect(out.map(\.url.path) == ["/Notes.md", "/dir"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VisibleChildrenFilter`
Expected: FAIL to compile — "cannot find 'VisibleChildrenFilter' in scope".

- [ ] **Step 3: Write the minimal implementation**

Create `Frameworks/FileSystemKit/VisibleChildrenFilter.swift`. (Match `FileNode`'s actual `name` accessor — if it has no `name`, use `$0.url.lastPathComponent`.)

```swift
import Foundation

/// The single source of truth for which children a sidebar tree shows. Pure (no
/// disk access): callers pass in the already-enumerated nodes. Replaces the
/// duplicated `visibleChildren` filters that previously had to be kept in
/// lockstep across FileTreeView and SidebarView.
public enum VisibleChildrenFilter {
    /// - Parameters:
    ///   - isPinned: true for the FAVORITES region (applies the pinned-hidden
    ///     filter); false for the browser (shows reality).
    public static func apply(_ nodes: [FileNode],
                             filesOnly: Bool,
                             isPinned: Bool,
                             showPinnedHidden: Bool,
                             hiddenPaths: Set<String>,
                             browseFilter: String) -> [FileNode] {
        var out = nodes
        if filesOnly { out = out.filter { !$0.isDirectory } }
        if isPinned, !showPinnedHidden {
            out = out.filter { !hiddenPaths.contains($0.url.path) }
        }
        if !browseFilter.isEmpty {
            out = out.filter { $0.isDirectory || $0.url.lastPathComponent.localizedCaseInsensitiveContains(browseFilter) }
        }
        return out
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VisibleChildrenFilter`
Expected: PASS (4 tests).

- [ ] **Step 5: Call the shared filter from `FileTreeView`**

In `FileTreeView.swift`, replace the body of `visibleChildren` with the shared helper:

```swift
    private var visibleChildren: [FileNode] {
        VisibleChildrenFilter.apply(children,
                                    filesOnly: model.filesOnly,
                                    isPinned: section == .pinned,
                                    showPinnedHidden: model.showPinnedHidden,
                                    hiddenPaths: model.hiddenPaths,
                                    browseFilter: model.browseFilter)
    }
```

- [ ] **Step 6: Call the shared filter from `SidebarView` and drop the drift warning**

In `SidebarView.swift`, replace `visibleChildren(of:section:includeHidden:)` (the disk read stays here; only the filtering is hoisted), and remove the "⚠️ CROSS-PHASE DRIFT" comment:

```swift
    /// Enumerate + filter a directory's visible children, using the SAME shared
    /// filter as the rendered tree so the keyboard order matches exactly.
    private func visibleChildren(of parent: URL, section: SidebarSection,
                                 includeHidden: Bool) -> [FileNode] {
        VisibleChildrenFilter.apply(model.children(of: parent, includeHidden: includeHidden),
                                    filesOnly: model.filesOnly,
                                    isPinned: section == .pinned,
                                    showPinnedHidden: model.showPinnedHidden,
                                    hiddenPaths: model.hiddenPaths,
                                    browseFilter: model.browseFilter)
    }
```

- [ ] **Step 7: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, zero warnings. (`FileSystemKit` is already a dependency of both `LumeApp` and the test target, so no `Package.swift` change is needed.)

- [ ] **Step 8: Run all tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all pass.

- [ ] **Step 9: Manual verify**

Run `./build-app.sh`, launch. Confirm filtering is unchanged in both regions: "Files only" hides folders; the FAVORITES eye toggle reveals/hides hidden items; the browser always shows reality; the text filter narrows both trees and keeps folders; keyboard order still matches what's rendered.

- [ ] **Step 10: Commit**

```bash
git add Frameworks/FileSystemKit/VisibleChildrenFilter.swift Tests/LumeCoreTests/VisibleChildrenFilterTests.swift Sources/LumeApp/Sidebar/FileTreeView.swift Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "refactor(sidebar): single shared VisibleChildrenFilter (kills cross-phase drift)

Hoist the duplicated children-visibility filter into one unit-tested pure
helper in FileSystemKit; FileTreeView and SidebarView both call it, so the
rendered order and keyboard order can no longer drift."
```

---

## Task 9: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Full clean build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: exit 0, **zero warnings** (matches the baseline).

- [ ] **Step 2: Full test run**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all `LumeCoreTests` pass, including the new `GroupRowOrder` and `VisibleChildrenFilter` suites.

- [ ] **Step 3: End-to-end manual smoke (GATE)**

Run `./build-app.sh`, launch, and confirm the two reported symptoms are gone:
1. **Clicking is instant and correct** — single-click selects + opens with no delay; double-click drills; ⌘/⇧ multi-select; group headers select-only; chevrons expand.
2. **Opening a tag group is fast** — repeated expand/collapse of a group with large favorites/browser trees open has no stutter or hang.

Plus regression sweep: keyboard nav (↑↓⇧↑⇧↓⌘A →←⏎ space type-ahead), drag-to-tag, drag-to-pin, rename, recolor, Copy Paths, hide/unhide, New Group, delete group, FSEvents refresh.

- [ ] **Step 4: Confirm git state is clean**

Run: `git status`
Expected: working tree clean (every change committed in its task).

---

## Self-Review

**Spec coverage** (audit → task):
- Issue 1 (triple click handlers / tap delay) → **Task 1** (+ contingency **Task 2**).
- Issue 2a (variable-view-count `ForEach`, GROUPS + tree) → **Task 3** (GROUPS) + **Task 4** (tree).
- Issue 2b (disk re-walk on group toggle; whole-dict signature) → **Task 5** (pure extraction) + **Task 6** (split signature, cache tree slice) + **Task 7** (version counter).
- Issue 2c (tap delay on expand) → resolved by **Task 1**.
- Broader audit: variable view count → Tasks 3–4; whole-dict copy → Task 7; triple click → Task 1; `visibleChildren` duplication ("CROSS-PHASE DRIFT") → **Task 8**; modifier-flag-in-closure correctness → resolved by Task 1 (native selection handles modifiers) or captured at event time by `ClickCatcher` in Task 2.
- `FileTreeView.init` synchronous disk read (audit "consider `.task`/seed-once"): **intentionally not changed** — it is cache-warm (dict lookup) after the first walk and seeding at init is what fixed the empty-tree `.onAppear` bug; touching it risks reintroducing that regression for no measured win. Noted, not actioned.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to"/"add validation" placeholders. Two explicit *verify-the-real-signature* notes (FileNode initializer/`name` accessor in Task 8) are calibration against existing code, with the exact `grep` to confirm — not deferred work.

**Type consistency:** `GroupRowOrder.ids(tagNames:expandedGroups:groupFilePaths:)` defined in Task 5, called in Task 6. `model.treeRowIDs` defined in Task 6 Step 1, used in Step 5. `metaVersion` defined in Task 7 Step 1, used Step 2. `GroupOrderSignature`/`TreeOrderSignature` defined in Task 6 Step 4, the former edited in Task 7 Step 2. `VisibleChildrenFilter.apply(_:filesOnly:isPinned:showPinnedHidden:hiddenPaths:browseFilter:)` defined in Task 8 Step 3, called identically in Steps 5–6 and the test in Step 1. `clickRow` is deleted in Task 1 and re-added (same signature) only in the contingency Task 2.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-05-sidebar-clicks-groups-perf.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, with review between tasks. Best here because Tasks 1, 3, 4, 6 have manual-run verification gates the human should confirm before the next change.
2. **Inline Execution** — execute tasks in this session via executing-plans, with checkpoints.

Which approach?
