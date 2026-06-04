# Colorful Tag Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give tags a color, make them removable, and replace the comma-string tag editors with a colored token field — turning tags from a write-only afterthought into a curatable workflow.

**Architecture:** A new non-optional `Tag.colorIndex` field (property-level default for safe SwiftData migration) maps into a centralized 8-color `TagPalette` that lives in `LumeCore` as raw RGB (no SwiftUI dependency); the app layer bridges `Swatch → Color`. `LibraryStore` gains granular tag operations — auto-color-on-create, recolor, rename-with-merge, delete, and orphan-pruning (the fix for "you can't remove a tag"). The UI gains three reusable pieces — `TagChip`, `TagSwatchPicker`, and a `TagField` token field — adopted by the single-file editor, the multi-select sheet, and the sidebar Tags list.

**Tech Stack:** Swift 6, SwiftData, SwiftUI (macOS 14+), Swift Testing, SPM (`LumeCore` library + `LumeApp` executable).

---

## Conventions for this plan

- **Build:** `swift build`
- **Run tests:** `swift test` — if the toolchain isn't found, set `DEVELOPER_DIR` the same way `tools/build-app.sh` does, e.g. `DEVELOPER_DIR=$(xcode-select -p) swift test`.
- **Run a single test:** `swift test --filter <testFunctionName>`
- **Run the app for manual verification:** `bash tools/build-app.sh` then launch; the app reads `LUME_OPEN_FOLDER` / `LUME_OPEN_FILE` env vars to point at a test folder.
- Core logic (Tasks 1–7) is unit-tested with Swift Testing in `Tests/LumeCoreTests/`. UI work (Tasks 8–14) is verified by building + manual checks, matching this codebase (only `LumeCore` has tests).
- Test container pattern is fixed by the existing suite — **always** retain the `ModelContainer` for the whole test body (`defer { withExtendedLifetime(container) {} }`), or SwiftData crashes with SIGTRAP. See `Tests/LumeCoreTests/LibraryStoreTests.swift:5-20`.

---

## File Structure

**Create:**
- `Sources/LumeCore/Library/TagPalette.swift` — the 8 canonical tag colors as raw RGB `Swatch`es + index-wrap helpers. Pure Foundation, no SwiftUI.
- `Sources/LumeApp/Sidebar/TagChip.swift` — `tagColor(_:Int) -> Color` bridge, the `TagChip` pill view, and the `TagSwatchPicker` 8-swatch picker.
- `Sources/LumeApp/Sidebar/TagField.swift` — the `TagField` token field (chips + inline add input + remove) plus a minimal wrapping `FlowLayout`.
- `Sources/LumeApp/Sidebar/TagRenameSheet.swift` — the rename dialog + the `TagRef` identifiable wrapper that drives `.sheet(item:)`.
- `Tests/LumeCoreTests/TagPaletteTests.swift` — palette/wrap tests.
- `Tests/LumeCoreTests/TagStoreTests.swift` — store tag-operation tests (color assignment, recolor, delete, prune, rename-merge).

**Modify:**
- `Sources/LumeCore/Library/Models.swift:34-42` — add `Tag.colorIndex`.
- `Sources/LumeCore/Library/LibraryStore.swift` — auto-color on create, `allTags()`, `colorIndex(forTagNamed:)`, `recolorTag`, `deleteTag`, `pruneOrphanTags`, `renameTag`; prune inside `setMeta`.
- `Sources/LumeApp/AppModel.swift` — add `applyTagNamesToSelection([String])`.
- `Sources/LumeApp/Sidebar/SidebarView.swift:191-203` — colored Tags section with context menu (Rename… / Color / Delete) + rename sheet.
- `Sources/LumeApp/Sidebar/FileTreeView.swift:364-438` — `RowMetaView` adopts `TagField`.
- `Sources/LumeApp/Sidebar/MultiTagSheet.swift` — adopts `TagField`.

---

## Task 1: TagPalette (Core)

**Files:**
- Create: `Sources/LumeCore/Library/TagPalette.swift`
- Test: `Tests/LumeCoreTests/TagPaletteTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/TagPaletteTests.swift`:

```swift
import Testing
@testable import LumeCore

@Test func paletteHasEightSwatches() {
    #expect(TagPalette.count == 8)
    #expect(TagPalette.swatches.count == 8)
}

@Test func wrapKeepsIndexInRange() {
    #expect(TagPalette.wrap(0) == 0)
    #expect(TagPalette.wrap(7) == 7)
    #expect(TagPalette.wrap(8) == 0)     // wraps past the end
    #expect(TagPalette.wrap(9) == 1)
    #expect(TagPalette.wrap(-1) == 7)    // negative wraps from the top
}

@Test func swatchAtWrapsOutOfRangeIndexes() {
    #expect(TagPalette.swatch(at: 9) == TagPalette.swatches[1])
    #expect(TagPalette.swatch(at: -1) == TagPalette.swatches[7])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter paletteHasEightSwatches`
Expected: FAIL — `cannot find 'TagPalette' in scope` (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LumeCore/Library/TagPalette.swift`:

```swift
import Foundation

/// The centralized tag color palette. Colors are stored as raw RGB so `LumeCore`
/// stays free of any SwiftUI dependency — the app layer bridges `Swatch → Color`
/// (see `TagChip.swift`). A `Tag` persists only a small `colorIndex` into this
/// table, so re-theming all tags is a one-file change here.
public enum TagPalette {
    public struct Swatch: Sendable, Equatable {
        public let name: String
        public let red: Double
        public let green: Double
        public let blue: Double
        public init(name: String, red: Double, green: Double, blue: Double) {
            self.name = name
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The 8 canonical tag colors (index 0…7).
    public static let swatches: [Swatch] = [
        Swatch(name: "Slate",  red: 0.42, green: 0.45, blue: 0.50),
        Swatch(name: "Red",    red: 0.90, green: 0.27, blue: 0.27),
        Swatch(name: "Orange", red: 0.96, green: 0.55, blue: 0.19),
        Swatch(name: "Yellow", red: 0.92, green: 0.76, blue: 0.18),
        Swatch(name: "Green",  red: 0.30, green: 0.69, blue: 0.39),
        Swatch(name: "Teal",   red: 0.20, green: 0.62, blue: 0.62),
        Swatch(name: "Blue",   red: 0.25, green: 0.50, blue: 0.90),
        Swatch(name: "Purple", red: 0.60, green: 0.38, blue: 0.82),
    ]

    public static var count: Int { swatches.count }

    /// Wrap any integer (possibly negative or out of range) into `0…count-1`, so
    /// a stored `colorIndex` can never index out of bounds even if the palette
    /// later shrinks.
    public static func wrap(_ raw: Int) -> Int {
        let c = count
        return ((raw % c) + c) % c
    }

    public static func swatch(at index: Int) -> Swatch {
        swatches[wrap(index)]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "paletteHasEightSwatches|wrapKeepsIndexInRange|swatchAtWrapsOutOfRangeIndexes"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/TagPalette.swift Tests/LumeCoreTests/TagPaletteTests.swift
git commit -m "feat(tags): add TagPalette with 8 canonical colors"
```

---

## Task 2: Add `Tag.colorIndex` field (Core model)

**Files:**
- Modify: `Sources/LumeCore/Library/Models.swift:34-42`
- Test: `Tests/LumeCoreTests/TagStoreTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/LumeCoreTests/TagStoreTests.swift` with the shared helper + the first test:

```swift
import Testing
import SwiftData
@testable import LumeCore

@MainActor
private func makeStore() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return (LibraryStore(context: container.mainContext), container)
}

@MainActor @Test func newTagDefaultsToColorIndexZero() throws {
    let (_, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    let t = Tag(name: "solo")
    #expect(t.colorIndex == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter newTagDefaultsToColorIndexZero`
Expected: FAIL — `value of type 'Tag' has no member 'colorIndex'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/LumeCore/Library/Models.swift`, replace the `Tag` model (lines 34-42) with:

```swift
@Model public final class Tag {
    @Attribute(.unique) public var name: String
    /// Index into `TagPalette.swatches` (0…7), resolved to a real color at the
    /// UI layer. A PROPERTY-LEVEL default is required so existing stores migrate
    /// without a launch crash when this additive field appears.
    public var colorIndex: Int = 0
    public var files: [FileMeta]

    public init(name: String, colorIndex: Int = 0, files: [FileMeta] = []) {
        self.name = name
        self.colorIndex = colorIndex
        self.files = files
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter newTagDefaultsToColorIndexZero`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/Models.swift Tests/LumeCoreTests/TagStoreTests.swift
git commit -m "feat(tags): add Tag.colorIndex with migration-safe default"
```

---

## Task 3: Auto-assign color on tag creation (Store)

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift:172-184` (tag creation) and add helpers
- Test: `Tests/LumeCoreTests/TagStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/TagStoreTests.swift`:

```swift
@MainActor @Test func tagsGetCyclingColorsOnCreation() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    // Each setMeta saves, so the next tag sees the prior one's count.
    store.setMeta(path: "/a.md", info: "", tagNames: ["first"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["second"])

    #expect(store.colorIndex(forTagNamed: "first") == 0)
    #expect(store.colorIndex(forTagNamed: "second") == 1)
    #expect(store.colorIndex(forTagNamed: "missing") == 0)   // unknown → 0
}

@MainActor @Test func allTagsReturnsEveryTagSorted() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["zebra"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["apple"])
    #expect(store.allTags().map(\.name) == ["apple", "zebra"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "tagsGetCyclingColorsOnCreation|allTagsReturnsEveryTagSorted"`
Expected: FAIL — `value of type 'LibraryStore' has no member 'colorIndex'` / `allTags`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/LumeCore/Library/LibraryStore.swift`, replace the private `tag(named:)` (lines 172-184) and extend the `// MARK: Tags` section so it reads:

```swift
    // MARK: Tags

    /// Every tag, sorted by name (also drives color cycling and orphan pruning).
    public func allTags() -> [Tag] {
        (try? context.fetch(
            FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)])
        )) ?? []
    }

    /// The palette index a brand-new tag should receive — cycles through the
    /// palette by current tag count so a fresh library spreads colors. Color
    /// collisions are cosmetic (the user can recolor), so a best-effort spread is
    /// fine; we don't try to guarantee uniqueness across an unsaved batch.
    private func nextColorIndex() -> Int {
        TagPalette.wrap(allTags().count)
    }

    /// The stored palette index for a tag, or 0 if it doesn't exist yet.
    public func colorIndex(forTagNamed name: String) -> Int {
        existingTag(named: name)?.colorIndex ?? 0
    }

    /// Fetch a tag by name, creating it (with the next cycling color) if absent.
    private func tag(named name: String) -> Tag {
        if let existing = existingTag(named: name) { return existing }
        let t = Tag(name: name, colorIndex: nextColorIndex())
        context.insert(t)
        return t
    }

    private func existingTag(named name: String) -> Tag? {
        var d = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == name })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "tagsGetCyclingColorsOnCreation|allTagsReturnsEveryTagSorted"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/TagStoreTests.swift
git commit -m "feat(tags): auto-assign cycling palette color on tag creation"
```

---

## Task 4: Recolor a tag (Store)

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift` (`// MARK: Tags` section)
- Test: `Tests/LumeCoreTests/TagStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/TagStoreTests.swift`:

```swift
@MainActor @Test func recolorTagPersistsAndWraps() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])

    store.recolorTag(named: "work", colorIndex: 5)
    #expect(store.colorIndex(forTagNamed: "work") == 5)

    // Out-of-range indexes are wrapped, never stored raw.
    store.recolorTag(named: "work", colorIndex: 9)
    #expect(store.colorIndex(forTagNamed: "work") == 1)

    // Recoloring a missing tag is a no-op (no crash).
    store.recolorTag(named: "ghost", colorIndex: 3)
    #expect(store.colorIndex(forTagNamed: "ghost") == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter recolorTagPersistsAndWraps`
Expected: FAIL — `LibraryStore` has no member `recolorTag`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/LumeCore/Library/LibraryStore.swift`, inside `// MARK: Tags`, add after `colorIndex(forTagNamed:)`:

```swift
    /// Change a tag's palette color. Out-of-range indexes are wrapped.
    public func recolorTag(named name: String, colorIndex: Int) {
        guard let t = existingTag(named: name) else { return }
        t.colorIndex = TagPalette.wrap(colorIndex)
        try? context.save()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter recolorTagPersistsAndWraps`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/TagStoreTests.swift
git commit -m "feat(tags): add recolorTag store operation"
```

---

## Task 5: Delete a tag + prune orphans (Store)

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift` (`// MARK: Tags` section)
- Test: `Tests/LumeCoreTests/TagStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/TagStoreTests.swift`:

```swift
@MainActor @Test func deleteTagRemovesItFromAllFiles() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work", "keep"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["work"])

    store.deleteTag(named: "work")

    #expect(store.files(taggedWith: "work").isEmpty)
    #expect(store.allTags().map(\.name) == ["keep"])
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["keep"])
    #expect(store.meta(for: "/b.md")?.tags.isEmpty == true)
}

@MainActor @Test func pruneOrphanTagsDeletesUnreferencedTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["orphan", "kept"])
    // Drop "orphan" from its only file by re-setting tags WITHOUT pruning here:
    if let m = store.meta(for: "/a.md") {
        m.tags = m.tags.filter { $0.name == "kept" }
    }

    let removed = store.pruneOrphanTags()
    #expect(removed == 1)
    #expect(store.allTags().map(\.name) == ["kept"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "deleteTagRemovesItFromAllFiles|pruneOrphanTagsDeletesUnreferencedTags"`
Expected: FAIL — `LibraryStore` has no member `deleteTag` / `pruneOrphanTags`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/LumeCore/Library/LibraryStore.swift`, inside `// MARK: Tags`, add after `recolorTag`:

```swift
    /// Delete a tag outright: detach it from every file it tags, then remove it.
    public func deleteTag(named name: String) {
        guard let t = existingTag(named: name) else { return }
        for file in t.files {
            file.tags.removeAll { $0.name == name }
        }
        context.delete(t)
        try? context.save()
    }

    /// Delete every tag no file references. This is the fix for "you can't remove
    /// a tag" — clearing a tag off its last file otherwise leaves a dangling
    /// entry in the sidebar forever. Returns how many tags were pruned.
    @discardableResult
    public func pruneOrphanTags() -> Int {
        let orphans = allTags().filter { $0.files.isEmpty }
        for t in orphans { context.delete(t) }
        if !orphans.isEmpty { try? context.save() }
        return orphans.count
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "deleteTagRemovesItFromAllFiles|pruneOrphanTagsDeletesUnreferencedTags"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/TagStoreTests.swift
git commit -m "feat(tags): add deleteTag and pruneOrphanTags store operations"
```

---

## Task 6: Rename a tag with merge-on-clash (Store)

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift` (`// MARK: Tags` section)
- Test: `Tests/LumeCoreTests/TagStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/TagStoreTests.swift`:

```swift
@MainActor @Test func renameTagToNewNameJustRenames() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])

    let ok = store.renameTag(named: "wip", to: "in-progress")
    #expect(ok == true)
    #expect(store.allTags().map(\.name) == ["in-progress"])
    #expect(store.meta(for: "/a.md")?.tags.map(\.name) == ["in-progress"])
}

@MainActor @Test func renameTagIntoExistingNameMerges() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["wip"])
    store.setMeta(path: "/b.md", info: "", tagNames: ["work"])
    store.setMeta(path: "/c.md", info: "", tagNames: ["wip", "work"])  // already both

    let ok = store.renameTag(named: "wip", to: "work")
    #expect(ok == true)
    // "wip" is gone; every wip-file now carries "work", de-duped on /c.md.
    #expect(store.allTags().map(\.name) == ["work"])
    #expect(store.paths(taggedWith: "work") == ["/a.md", "/b.md", "/c.md"])
    #expect(store.meta(for: "/c.md")?.tags.map(\.name) == ["work"])
}

@MainActor @Test func renameTagRejectsBlankOrUnchangedOrMissing() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }
    store.setMeta(path: "/a.md", info: "", tagNames: ["work"])

    #expect(store.renameTag(named: "work", to: "   ") == false)
    #expect(store.renameTag(named: "work", to: "work") == false)
    #expect(store.renameTag(named: "ghost", to: "x") == false)
    #expect(store.allTags().map(\.name) == ["work"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "renameTagToNewNameJustRenames|renameTagIntoExistingNameMerges|renameTagRejectsBlankOrUnchangedOrMissing"`
Expected: FAIL — `LibraryStore` has no member `renameTag`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/LumeCore/Library/LibraryStore.swift`, inside `// MARK: Tags`, add after `pruneOrphanTags`:

```swift
    /// Rename a tag. If `newName` already exists, MERGE: every file on the old
    /// tag is moved onto the existing tag (de-duped) and the old tag is deleted.
    /// Returns false when the source is missing or the name is blank/unchanged.
    @discardableResult
    public func renameTag(named oldName: String, to rawNewName: String) -> Bool {
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName,
              let source = existingTag(named: oldName) else { return false }

        if let target = existingTag(named: newName) {
            // Merge. Snapshot first — we mutate each file's `tags` in the loop.
            let affected = source.files
            for file in affected {
                if !file.tags.contains(where: { $0.name == newName }) {
                    file.tags.append(target)
                }
                file.tags.removeAll { $0.name == oldName }
            }
            context.delete(source)
        } else {
            source.name = newName
        }
        try? context.save()
        return true
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "renameTagToNewNameJustRenames|renameTagIntoExistingNameMerges|renameTagRejectsBlankOrUnchangedOrMissing"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/TagStoreTests.swift
git commit -m "feat(tags): add renameTag with merge-on-clash"
```

---

## Task 7: Prune orphans automatically inside `setMeta` (Store)

This wires the orphan fix into the normal edit path: removing a tag from its last file via any editor now deletes the tag.

**Files:**
- Modify: `Sources/LumeCore/Library/LibraryStore.swift:109-125` (`setMeta`)
- Test: `Tests/LumeCoreTests/TagStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LumeCoreTests/TagStoreTests.swift`:

```swift
@MainActor @Test func setMetaPrunesNewlyOrphanedTags() throws {
    let (store, container) = try makeStore()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "", tagNames: ["solo"])
    #expect(store.allTags().map(\.name) == ["solo"])

    // Remove the only tag from the only file → tag must disappear, not linger.
    store.setMeta(path: "/a.md", info: "", tagNames: [])
    #expect(store.allTags().isEmpty)

    // A tag still used by another file survives.
    store.setMeta(path: "/x.md", info: "", tagNames: ["shared"])
    store.setMeta(path: "/y.md", info: "", tagNames: ["shared"])
    store.setMeta(path: "/x.md", info: "", tagNames: [])
    #expect(store.allTags().map(\.name) == ["shared"])
    #expect(store.paths(taggedWith: "shared") == ["/y.md"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter setMetaPrunesNewlyOrphanedTags`
Expected: FAIL — after clearing tags, `allTags()` still contains `"solo"` (orphan lingers).

- [ ] **Step 3: Write minimal implementation**

In `Sources/LumeCore/Library/LibraryStore.swift`, in `setMeta`, change the tail of the method (currently lines 123-124) from:

```swift
        meta.tags = uniqueNames.map { tag(named: $0) }
        try? context.save()
    }
```

to:

```swift
        meta.tags = uniqueNames.map { tag(named: $0) }
        try? context.save()
        // Removing a tag from its last file would otherwise leave a dangling
        // tag in the sidebar; prune so "clear the field" actually removes it.
        pruneOrphanTags()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter setMetaPrunesNewlyOrphanedTags`
Expected: PASS.

- [ ] **Step 5: Run the full Core suite to confirm no regressions**

Run: `swift test`
Expected: PASS — all existing `LibraryStoreTests` (including `setMetaReplacesTagsOnUpdate`, `setMetaUpsertsAndTagsAreReused`) still pass alongside the new tag tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeCore/Library/LibraryStore.swift Tests/LumeCoreTests/TagStoreTests.swift
git commit -m "feat(tags): prune orphan tags on setMeta so tags become removable"
```

---

## Task 8: TagChip + TagSwatchPicker + color bridge (UI)

No unit tests (SwiftUI view); verified by compile + later manual checks.

**Files:**
- Create: `Sources/LumeApp/Sidebar/TagChip.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import LumeCore

/// Bridge a stored `Tag.colorIndex` to a SwiftUI `Color` via the shared palette.
/// This is the ONLY place index → Color happens in the app.
func tagColor(_ index: Int) -> Color {
    let s = TagPalette.swatch(at: index)
    return Color(red: s.red, green: s.green, blue: s.blue)
}

/// A compact colored pill for a single tag. When `onRemove` is non-nil an ✕
/// button appears (used inside the editable token field).
struct TagChip: View {
    let name: String
    let colorIndex: Int
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tagColor(colorIndex)).frame(width: 7, height: 7)
            Text(name).font(.caption).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove tag")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tagColor(colorIndex).opacity(0.18)))
        .overlay(Capsule().strokeBorder(tagColor(colorIndex).opacity(0.55), lineWidth: 1))
    }
}

/// A horizontal row of the 8 palette swatches. The current color is ringed.
/// Reused by the chip recolor popover and (as a Menu) the sidebar context menu.
struct TagSwatchPicker: View {
    var current: Int
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<TagPalette.count, id: \.self) { i in
                Button { onPick(i) } label: {
                    Circle()
                        .fill(tagColor(i))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(
                                .primary,
                                lineWidth: i == TagPalette.wrap(current) ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
                .help(TagPalette.swatch(at: i).name)
            }
        }
        .padding(8)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LumeApp/Sidebar/TagChip.swift
git commit -m "feat(tags): add TagChip, TagSwatchPicker, and color bridge"
```

---

## Task 9: Colorize the sidebar Tags section + context menu (UI)

**Files:**
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift:191-203` (and add a `@State` near line 14)

- [ ] **Step 1: Add rename state**

In `SidebarView`, after `@FocusState private var filterFocused: Bool` (line 14), add:

```swift
    /// Drives the tag rename sheet (non-nil while renaming a specific tag).
    @State private var renamingTag: TagRef?
```

- [ ] **Step 2: Replace `tagsSection`**

Replace the whole `tagsSection` (lines 191-203) with:

```swift
    @ViewBuilder private var tagsSection: some View {
        Section("Tags") {
            ForEach(tags) { tag in
                let active = model.activeTagFilter == tag.name
                HStack(spacing: 6) {
                    Image(systemName: active ? "tag.fill" : "tag")
                        .foregroundStyle(tagColor(tag.colorIndex))
                    Text(tag.name)
                        .foregroundStyle(active ? Color.primary : .secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.activeTagFilter = active ? nil : tag.name
                }
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") {
                        renamingTag = TagRef(name: tag.name)
                    }
                    Menu("Color") {
                        ForEach(0..<TagPalette.count, id: \.self) { i in
                            Button(TagPalette.swatch(at: i).name) {
                                model.store?.recolorTag(named: tag.name, colorIndex: i)
                            }
                        }
                    }
                    Divider()
                    Button("Delete Tag", systemImage: "trash", role: .destructive) {
                        if model.activeTagFilter == tag.name {
                            model.activeTagFilter = nil
                        }
                        model.store?.deleteTag(named: tag.name)
                    }
                }
            }
        }
        .sheet(item: $renamingTag) { ref in
            TagRenameSheet(model: model, oldName: ref.name) {
                renamingTag = nil
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: FAIL — `cannot find 'TagRef'` / `'TagRenameSheet'` in scope (created next task). This is expected; proceed to Task 10, then build.

- [ ] **Step 4: Defer commit**

Do not commit yet — commit together with Task 10 (this task references types created there).

---

## Task 10: TagRenameSheet (UI)

**Files:**
- Create: `Sources/LumeApp/Sidebar/TagRenameSheet.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Identifiable wrapper so a tag name can drive a SwiftUI `.sheet(item:)`.
struct TagRef: Identifiable {
    let id = UUID()
    let name: String
}

/// Rename a tag. Renaming onto an existing tag MERGES them — the merge logic
/// lives in `LibraryStore.renameTag`, this sheet just collects the new name.
struct TagRenameSheet: View {
    let model: AppModel
    let oldName: String
    let onClose: () -> Void

    @State private var newName = ""
    @State private var didInit = false

    private var trimmed: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tag").font(.headline)
            Text("Renaming to a tag that already exists merges them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Tag name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed == oldName)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            // Seed once; `.onAppear` can re-fire and would clobber edits.
            if !didInit { newName = oldName; didInit = true }
        }
    }

    private func commit() {
        model.store?.renameTag(named: oldName, to: newName)
        onClose()
    }
}
```

- [ ] **Step 2: Build to verify Tasks 9 + 10 compile together**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit Tasks 9 + 10**

```bash
git add Sources/LumeApp/Sidebar/SidebarView.swift Sources/LumeApp/Sidebar/TagRenameSheet.swift
git commit -m "feat(tags): colorize sidebar tags with rename/recolor/delete menu"
```

---

## Task 11: TagField token field + FlowLayout (UI)

**Files:**
- Create: `Sources/LumeApp/Sidebar/TagField.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import LumeCore

/// A token field for tags: existing tags render as removable colored chips, and
/// an inline text input commits a new tag on Return or comma. Binds to a
/// `[String]` of names; `colorIndex` resolves each name's color live so recolors
/// elsewhere reflect here. Pure UI — persistence is the caller's job (on change).
struct TagField: View {
    @Binding var names: [String]
    /// name → palette index (look up against a reactive @Query in the parent).
    let colorIndex: (String) -> Int
    var placeholder = "add tag"

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                TagChip(name: name, colorIndex: colorIndex(name)) { remove(name) }
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(minWidth: 70)
                .focused($focused)
                .onSubmit(commitDraft)
                .onChange(of: draft) { _, value in
                    if value.contains(",") { commitDraft() }   // comma commits too
                }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func commitDraft() {
        let candidates = draft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for c in candidates where !names.contains(c) { names.append(c) }
        draft = ""
    }

    private func remove(_ name: String) {
        names.removeAll { $0 == name }
    }
}

/// Minimal wrapping layout (a left-to-right flow that wraps to a new row when it
/// runs out of width). Used to lay out tag chips + the input.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth == .infinity ? x : maxWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LumeApp/Sidebar/TagField.swift
git commit -m "feat(tags): add TagField token field with wrapping FlowLayout"
```

---

## Task 12: RowMetaView adopts TagField (UI)

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:364-438` (`RowMetaView`)

- [ ] **Step 1: Swap state, query, and body**

In `RowMetaView`:

1. Add a reactive tags query and replace the `tagsText` state. Change the property block (lines 369-373) from:

```swift
    @Environment(\.modelContext) private var context
    @State private var tagsText = ""
    @State private var notes = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
```

to:

```swift
    @Environment(\.modelContext) private var context
    @Query private var allTags: [Tag]
    @State private var tagNames: [String] = []
    @State private var notes = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
```

2. Replace the tag `TextField` (lines 382-386) inside the `HStack` with the token field:

```swift
                TagField(names: $tagNames, colorIndex: colorIndex)
                    .onChange(of: tagNames) { _, _ in scheduleSave() }
```

3. Add a color lookup helper. After the `notesOpen` computed property (line 377), add:

```swift
    /// Live color for a tag name from the reactive @Query (0 until first saved).
    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }
```

4. Update `load()` (line 417) from:

```swift
        tagsText = meta?.tags.map(\.name).joined(separator: ", ") ?? ""
```

to:

```swift
        tagNames = meta?.tags.map(\.name) ?? []
```

5. Update `save()` (lines 431-437) from:

```swift
    private func save() {
        let store = LibraryStore(context: context)
        let tagNames = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.setMeta(path: url.path, info: notes, tagNames: tagNames,
                      displayName: store.displayName(for: url.path) ?? "")
    }
```

to:

```swift
    private func save() {
        let store = LibraryStore(context: context)
        store.setMeta(path: url.path, info: notes, tagNames: tagNames,
                      displayName: store.displayName(for: url.path) ?? "")
    }
```

- [ ] **Step 2: Confirm `Query`/`Tag` are imported**

`FileTreeView.swift` must `import SwiftData` and `import LumeCore` at the top (it already imports `LumeCore` and uses `@Query` elsewhere — verify both `import SwiftData` and `import LumeCore` are present; add `import SwiftData` if missing).

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(tags): RowMetaView uses colored TagField token editor"
```

---

## Task 13: MultiTagSheet adopts TagField (UI)

**Files:**
- Modify: `Sources/LumeApp/Sidebar/MultiTagSheet.swift`
- Modify: `Sources/LumeApp/AppModel.swift:200-215` (add typed helper)

- [ ] **Step 1: Add a typed apply method to AppModel**

In `Sources/LumeApp/AppModel.swift`, after `applyTagsToSelection(_:)` (ends line 215), add:

```swift
    /// Apply an explicit list of tag names to every selected path (replaces each
    /// path's tags). Used by the token-field multi-edit sheet.
    func applyTagNamesToSelection(_ names: [String]) {
        applyTagsToSelection(names.joined(separator: ","))
    }
```

- [ ] **Step 2: Rewrite MultiTagSheet to use TagField**

Replace the entire body of `Sources/LumeApp/Sidebar/MultiTagSheet.swift` with:

```swift
import SwiftUI
import SwiftData
import LumeCore

struct MultiTagSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool

    @Query private var allTags: [Tag]
    @State private var tagNames: [String] = []

    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tags for \(model.selectedURLs.count) items")
                .font(.headline)
            Text("Applies to every selected item, replacing their tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TagField(names: $tagNames, colorIndex: colorIndex,
                     placeholder: "e.g. work, prod, review")
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.applyTagNamesToSelection(tagNames)
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

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeApp/Sidebar/MultiTagSheet.swift Sources/LumeApp/AppModel.swift
git commit -m "feat(tags): MultiTagSheet uses colored TagField token editor"
```

---

## Task 14: Full build, test, and manual verification

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: PASS — all `LumeCoreTests` green (existing + new `TagPaletteTests`, `TagStoreTests`).

- [ ] **Step 2: Build the app bundle**

Run: `bash tools/build-app.sh`
Expected: Build + install succeed with no errors.

- [ ] **Step 3: Manual verification checklist**

Launch the app against a test folder (e.g. `LUME_OPEN_FOLDER=/some/test/dir`) and confirm:

- [ ] Selecting a file shows the token field; typing `work` + Return makes a **colored** chip appear; the same tag shows in the sidebar Tags list with the same color.
- [ ] Adding a second new tag gets a **different** color (cycling).
- [ ] Clicking the ✕ on a chip removes the tag; if that was the tag's last file, it **disappears from the sidebar** (orphan prune).
- [ ] Right-click a sidebar tag → **Color** → pick a color; the chip and sidebar swatch both update immediately.
- [ ] Right-click a sidebar tag → **Rename…**; renaming to a brand-new name updates everywhere; renaming onto an existing tag **merges** (files consolidate, old tag vanishes).
- [ ] Right-click a sidebar tag → **Delete Tag**; it's removed from all files and the sidebar; if it was the active filter, the filter clears.
- [ ] Multi-select files → **Edit Tags…**; the sheet's token field applies colored tags to all selected files.
- [ ] Clicking a sidebar tag still filters the browser (existing behavior intact).

- [ ] **Step 4: Commit any verification fixups, then finish the branch**

If manual checks surfaced issues, fix them with a focused commit. When everything passes, use the `superpowers:finishing-a-development-branch` skill to decide merge/PR.

---

## Self-Review (completed during authoring)

**1. Spec coverage** — every element of the S432 design maps to a task:
- Data model `Tag.colorIndex` → Task 2.
- Palette abstraction (`TagPalette`, 8 colors) → Task 1.
- Reusable UI component (`TagChip`) → Task 8; token field (`TagField`) → Task 11.
- Store refactor (granular add/remove/rename/recolor/delete + auto-cleanup) → Tasks 3–7.
- UI surfaces (RowMetaView, MultiTagSheet, sidebar context menu) → Tasks 9, 12, 13.
- Reactivity (@Query) → Tasks 9/12/13 use `@Query(\Tag)` for live colors.
- Decisions: auto-assign + pick-on-create (auto color on create in Task 3; pick via swatch picker/menu in Tasks 8–9), 8 colors (Task 1), rename dialog + inline recolor (Tasks 8–10), merge-on-clash (Task 6).

**2. Placeholder scan** — no TBD/"handle errors"/"similar to" placeholders; every code step shows full code.

**3. Type consistency** — method names are stable across tasks: `colorIndex(forTagNamed:)`, `recolorTag(named:colorIndex:)`, `deleteTag(named:)`, `pruneOrphanTags()`, `renameTag(named:to:)`, `allTags()`; UI helpers `tagColor(_:)`, `TagChip(name:colorIndex:onRemove:)`, `TagField(names:colorIndex:placeholder:)`, `TagRef(name:)`, `TagRenameSheet(model:oldName:onClose:)`, `applyTagNamesToSelection(_:)`. The view-local `colorIndex(_ name:) -> Int` helper (UI) and the store's `colorIndex(forTagNamed:)` are intentionally distinct (different layers).

**Known cosmetic limitation (acceptable, YAGNI):** within a single `setMeta` call that creates several new tags at once, the unsaved tags may share a color index until the next save re-cycles; colors are user-recolorable, so this is not worth de-duping. Noted in `nextColorIndex()`.
