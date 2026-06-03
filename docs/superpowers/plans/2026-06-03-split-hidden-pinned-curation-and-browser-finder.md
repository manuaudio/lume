# Split Hidden: Pinned Curation vs Browser Finder-Hidden — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the single `showHidden` toggle into two independent, region-scoped systems — `showPinnedHidden` (curation: reveal items hidden from FAVORITES) and `showBrowserHidden` (reveal Finder dotfiles in OPEN FOLDER).

**Architecture:** No schema change. `FileMeta.hidden` is reinterpreted as "hidden from FAVORITES only." Two persisted `AppModel` flags replace one. `SidebarView` moves the hidden control out of the top bar and into per-region section headers (shared `SectionHeader` helper). `FileTreeView` forks behavior on its existing `section` value: `.pinned` filters on `hiddenPaths` (gated by `showPinnedHidden`) and always enumerates with `includeHidden: false`; `.browser` ignores `hiddenPaths` and enumerates with `includeHidden: showBrowserHidden`. `RowMenu` shows Hide/Un-hide only on nested pinned rows.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AppKit, SPM. macOS app target `LumeApp`. Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`. No LumeCore changes (`enumerate(includeHidden:)` already exists).

**Spec:** `docs/superpowers/specs/2026-06-03-split-hidden-pinned-curation-and-browser-finder.md`

---

## File Structure

All changes are in `LumeApp` (the view + model layer). No `LumeCore`, no tests change.

- `Sources/LumeApp/AppModel.swift` — replace `showHidden` with `showPinnedHidden` + `showBrowserHidden` (both persisted; same UserDefaults pattern as `filesOnly`).
- `Sources/LumeApp/Sidebar/SidebarView.swift` — remove top-bar Show-hidden toggle; add `SectionHeader` helper view; wire eye toggles into FAVORITES and OPEN FOLDER headers; `visibleFavorites` filters on `showPinnedHidden`.
- `Sources/LumeApp/Sidebar/FileTreeView.swift` — region-fork `includeHidden`, `visibleChildren` hidden filter, `reload()`, and `.onChange`; gate dim/un-hide affordance to `.pinned`; gate `RowMenu` Hide/Un-hide to nested pinned rows; restructure Pin/Unpin.

There is no unit-testable pure logic in this change — it is entirely SwiftUI view wiring and `@Observable` flags. Verification is **compile-clean per task** plus a final **drive-the-app** pass (Task 5) against the spec's acceptance checklist. `LumeCoreTests` must continue to pass untouched.

---

## Task 1: AppModel — two flags replace one

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift:33` (the `showHidden` property)
- Modify: `Sources/LumeApp/AppModel.swift:56` (the `init` seed)

- [ ] **Step 1: Replace the property declaration**

In `Sources/LumeApp/AppModel.swift`, replace the single line 33:

```swift
    /// When true, hidden paths are shown (dimmed) instead of omitted.
    var showHidden = false { didSet { UserDefaults.standard.set(showHidden, forKey: "lume.showHidden") } }
```

with the two region-scoped flags:

```swift
    /// FAVORITES curation: when true, items hidden from Favorites are revealed
    /// (dimmed, with an un-hide affordance) instead of omitted.
    var showPinnedHidden = false { didSet { UserDefaults.standard.set(showPinnedHidden, forKey: "lume.showPinnedHidden") } }
    /// OPEN FOLDER browser: when true, Finder-hidden dotfiles (.env, .claude…)
    /// are revealed. Independent of `showPinnedHidden`.
    var showBrowserHidden = false { didSet { UserDefaults.standard.set(showBrowserHidden, forKey: "lume.showBrowserHidden") } }
```

- [ ] **Step 2: Update the init seed**

In `init()`, replace line 56:

```swift
        showHidden = UserDefaults.standard.bool(forKey: "lume.showHidden")
```

with:

```swift
        showPinnedHidden = UserDefaults.standard.bool(forKey: "lume.showPinnedHidden")
        showBrowserHidden = UserDefaults.standard.bool(forKey: "lume.showBrowserHidden")
```

(The old `lume.showHidden` key is intentionally abandoned; both new flags default to `false`.)

- [ ] **Step 3: Verify AppModel has no remaining `showHidden` references**

Run: `grep -n "showHidden" Sources/LumeApp/AppModel.swift`
Expected: no output (zero matches).

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -30`
Expected: compile errors ONLY in `SidebarView.swift` and `FileTreeView.swift` referencing the now-removed `model.showHidden` (those are fixed in Tasks 2–4). AppModel.swift itself must produce no errors. If AppModel.swift has errors, fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeApp/AppModel.swift
git commit -m "feat(app): split showHidden into showPinnedHidden + showBrowserHidden"
```

---

## Task 2: SidebarView — SectionHeader helper, header toggles, drop top-bar toggle

**Files:**
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift:39` (`visibleFavorites`)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift:97-119` (`topBar` — remove Show-hidden Toggle)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift:153-187` (`pinnedSection` header)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift:207-216` (`browserSection` header)
- Create: a `SectionHeader` struct at the end of `SidebarView.swift`

- [ ] **Step 1: Point `visibleFavorites` at the pinned flag**

Replace line 39:

```swift
        model.showHidden ? favorites : favorites.filter { !hiddenPaths.contains($0.path) }
```

with:

```swift
        model.showPinnedHidden ? favorites : favorites.filter { !hiddenPaths.contains($0.path) }
```

- [ ] **Step 2: Remove the Show-hidden Toggle from the top bar**

In `topBar`, delete the entire second `Toggle` block (lines 107–112), leaving only the "Files only" toggle and the `Spacer()`. After the edit the `HStack` inside `topBar` reads exactly:

```swift
            HStack {
                Toggle(isOn: Binding(get: { model.filesOnly },
                                     set: { model.filesOnly = $0 })) {
                    Label("Files only", systemImage: "doc")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
            }
```

- [ ] **Step 3: Add the `SectionHeader` helper**

At the very end of `Sources/LumeApp/Sidebar/SidebarView.swift` (after the closing brace of `struct SidebarView`), add:

```swift
/// A section header with a trailing borderless eye toggle. Used identically by
/// the FAVORITES and OPEN FOLDER regions so both controls look the same.
struct SectionHeader: View {
    let title: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button { isOn.toggle() } label: {
                Image(systemName: isOn ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(help)
        }
    }
}
```

- [ ] **Step 4: Wire the FAVORITES header**

In `pinnedSection`, change the section from a string-titled `Section("FAVORITES") { … }` to a `header:`-based one. Replace:

```swift
    @ViewBuilder private var pinnedSection: some View {
        Section("FAVORITES") {
```

with:

```swift
    @ViewBuilder private var pinnedSection: some View {
        Section {
```

Then, immediately before the closing brace of `pinnedSection` (after the `}` that closes the `if favorites.isEmpty { … } else { … }`), add the `header:` argument so the `Section` reads `Section { … } header: { … }`. Concretely, the section's closing lines become:

```swift
            }
        } header: {
            SectionHeader(title: "FAVORITES",
                          isOn: Binding(get: { model.showPinnedHidden },
                                        set: { model.showPinnedHidden = $0 }),
                          help: "Show items hidden from Favorites")
        }
    }
```

- [ ] **Step 5: Wire the OPEN FOLDER header**

In `browserSection`, replace:

```swift
    @ViewBuilder private var browserSection: some View {
        Section(openFolderTitle) {
            pathPeekBar
            if let root = model.browseRoot {
                FileTreeView(parent: root, model: model, names: names,
                             hiddenPaths: hiddenPaths, section: .browser, depth: 0)
                    .opacity(model.pathPeek ? 0.4 : 1)
            }
        }
    }
```

with:

```swift
    @ViewBuilder private var browserSection: some View {
        Section {
            pathPeekBar
            if let root = model.browseRoot {
                FileTreeView(parent: root, model: model, names: names,
                             hiddenPaths: hiddenPaths, section: .browser, depth: 0)
                    .opacity(model.pathPeek ? 0.4 : 1)
            }
        } header: {
            SectionHeader(title: openFolderTitle,
                          isOn: Binding(get: { model.showBrowserHidden },
                                        set: { model.showBrowserHidden = $0 }),
                          help: "Show hidden files (.env, .claude…)")
        }
    }
```

- [ ] **Step 6: Verify no `showHidden` left in SidebarView**

Run: `grep -n "model.showHidden" Sources/LumeApp/Sidebar/SidebarView.swift`
Expected: no output.

- [ ] **Step 7: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -30`
Expected: `SidebarView.swift` produces no errors. Remaining errors must be only in `FileTreeView.swift` (fixed in Tasks 3–4).

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeApp/Sidebar/SidebarView.swift
git commit -m "feat(app): move hidden control into per-region section headers"
```

---

## Task 3: FileTreeView — region-forked enumeration, filtering, and dim affordance

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:28` (init seed)
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:45-49` (`.onChange` watcher)
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:51-66` (`visibleChildren`)
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:68-70` (`reload()`)
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:115-121` (dim + un-hide affordance in `SidebarItemRow`)

- [ ] **Step 1: Fork `includeHidden` in the init seed**

Replace line 28:

```swift
        _children = State(initialValue: model.children(of: parent, includeHidden: model.showHidden))
```

with:

```swift
        // Browser shows reality (Finder dotfiles gated by the browser toggle);
        // pinned is a curation surface and never reveals OS-hidden files here.
        let includeHidden = (section == .browser) ? model.showBrowserHidden : false
        _children = State(initialValue: model.children(of: parent, includeHidden: includeHidden))
```

- [ ] **Step 2: Watch the browser flag instead of `showHidden`**

Replace line 48:

```swift
        // Re-enumerate when "Show hidden" flips so dotfiles appear/disappear.
        .onChange(of: model.showHidden) { _, _ in reload() }
```

with:

```swift
        // Re-enumerate when the browser hidden toggle flips so dotfiles
        // appear/disappear. Harmless no-op for the pinned tree (it always
        // enumerates with includeHidden: false; reload() re-applies that).
        .onChange(of: model.showBrowserHidden) { _, _ in reload() }
```

- [ ] **Step 3: Fork the hidden filter in `visibleChildren`**

Replace the block at lines 54–56:

```swift
        if !model.showHidden {
            nodes = nodes.filter { !hiddenPaths.contains($0.url.path) }
        }
```

with (pinned-only curation filter; browser never filters on `FileMeta.hidden`):

```swift
        // Curation filter: only the FAVORITES region hides items by FileMeta.hidden,
        // and only when the pinned reveal toggle is off. The browser shows reality.
        if section == .pinned, !model.showPinnedHidden {
            nodes = nodes.filter { !hiddenPaths.contains($0.url.path) }
        }
```

- [ ] **Step 4: Fork `includeHidden` in `reload()`**

Replace lines 68–70:

```swift
    private func reload() {
        children = model.children(of: parent, includeHidden: model.showHidden)
    }
```

with:

```swift
    private func reload() {
        let includeHidden = (section == .browser) ? model.showBrowserHidden : false
        children = model.children(of: parent, includeHidden: includeHidden)
    }
```

- [ ] **Step 5: Gate the dim + un-hide affordance to `.pinned`**

In `SidebarItemRow.body`, replace the un-hide button block (lines 115–119):

```swift
                if model.showHidden, isHidden {
                    Button { model.unhide(url) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help("Un-hide")
                }
```

with:

```swift
                if section == .pinned, model.showPinnedHidden, isHidden {
                    Button { model.unhide(url) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help("Un-hide")
                }
```

- [ ] **Step 6: Dim only in the pinned region**

Replace line 121:

```swift
            .opacity(isHidden ? 0.45 : 1)
```

with (a path flagged hidden still appears un-dimmed in the browser, which shows reality):

```swift
            .opacity(section == .pinned && isHidden ? 0.45 : 1)
```

- [ ] **Step 7: Verify no `showHidden` left in FileTreeView**

Run: `grep -n "model.showHidden" Sources/LumeApp/Sidebar/FileTreeView.swift`
Expected: no output. (One `RowMenu` reference remains in Task 4 scope but it does not use `showHidden`, so this should already be clean.)

- [ ] **Step 8: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -30`
Expected: `Compiling …` then `Build complete!` — the whole project now compiles clean.

- [ ] **Step 9: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): region-fork hidden filtering and dim affordance in FileTreeView"
```

---

## Task 4: RowMenu — Hide only on nested pinned rows; restructure Pin/Unpin

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift:246-285` (the `Hide/Un-hide` and `Pin/Unpin` items in `RowMenu.body`)

**Context:** `RowMenu` already has `url`, `isDirectory`, `section`, `hiddenPaths`, `model`, and the computed `multi`. The Hide/Un-hide button must appear ONLY for a nested item inside a pinned folder (`section == .pinned && !model.isPinned(url)`). A top-level favorite (`section == .pinned && model.isPinned(url)`) shows Unpin instead; the two never both apply. The browser shows Pin/Unpin (single-row) as the way items enter Favorites, and never shows Hide.

- [ ] **Step 1: Gate the Hide/Un-hide button**

Replace the Hide/Un-hide block (currently at lines 247–257, beginning with the `// If the clicked row isn't part of the selection…` comment and ending at `.keyboardShortcut(.delete, modifiers: .command)`):

```swift
            // If the clicked row isn't part of the selection, judge by that row
            // (right-click adopts it); otherwise judge by the whole selection.
            // The action re-derives state AFTER ensureSelected() so label and
            // action can't disagree.
            let allHidden = model.selectionIsAllHidden(hiddenPaths)
                || (!model.selectedRowIDs.contains(rowID) && hiddenPaths.contains(url.path))
            Button(allHidden ? "Un-hide" : "Hide",
                   systemImage: allHidden ? "eye" : "eye.slash") {
                ensureSelected()
                model.setHiddenForSelection(!model.selectionIsAllHidden(hiddenPaths))
            }
            .keyboardShortcut(.delete, modifiers: .command)
```

with (wrapped so it only renders for nested pinned rows — a pinned-region row that is not itself a top-level favorite):

```swift
            // Hide/Un-hide curates the FAVORITES view, so it applies ONLY to a
            // nested item inside a pinned folder — never a top-level favorite
            // (use Unpin) and never the browser (which shows reality).
            if section == .pinned && !model.isPinned(url) {
                // If the clicked row isn't part of the selection, judge by that
                // row (right-click adopts it); otherwise judge by the whole
                // selection. The action re-derives state AFTER ensureSelected()
                // so label and action can't disagree.
                let allHidden = model.selectionIsAllHidden(hiddenPaths)
                    || (!model.selectedRowIDs.contains(rowID) && hiddenPaths.contains(url.path))
                Button(allHidden ? "Un-hide" : "Hide",
                       systemImage: allHidden ? "eye" : "eye.slash") {
                    ensureSelected()
                    model.setHiddenForSelection(!model.selectionIsAllHidden(hiddenPaths))
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
```

- [ ] **Step 2: Restructure Pin/Unpin**

Replace the Pin/Unpin block (currently at lines 276–285):

```swift
            if section == .browser && !multi {
                Button(model.isPinned(url) ? "Unpin" : "Pin",
                       systemImage: model.isPinned(url) ? "pin.slash" : "pin") {
                    ensureSelected(); model.togglePin(url, isDirectory: isDirectory)
                }
            } else {
                Button("Unpin", systemImage: "pin.slash") {
                    ensureSelected(); model.unpinSelection()
                }
            }
```

with (browser = Pin/Unpin toggle to enter Favorites; pinned = Unpin only for a top-level favorite; nested pinned rows get neither — Hide curates them):

```swift
            if section == .browser {
                if !multi {
                    Button(model.isPinned(url) ? "Unpin" : "Pin",
                           systemImage: model.isPinned(url) ? "pin.slash" : "pin") {
                        ensureSelected(); model.togglePin(url, isDirectory: isDirectory)
                    }
                }
            } else if model.isPinned(url) {
                Button("Unpin", systemImage: "pin.slash") {
                    ensureSelected(); model.unpinSelection()
                }
            }
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -30`
Expected: `Build complete!`

- [ ] **Step 4: Run the unchanged LumeCore tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`
Expected: all tests pass (LumeCore is untouched; this confirms nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): scope Hide to nested pinned rows; restructure Pin/Unpin"
```

---

## Task 5: Build the app bundle and drive the acceptance checklist

**Files:** none (verification only)

This task builds the real `.app` and drives it against the spec's acceptance criteria. Use a test folder containing: at least one normal subfolder with files, at least one dotfile (e.g. `.env`, `.claude`), and a pinned favorite folder.

- [ ] **Step 1: Build the app bundle**

Run: `./tools/build-app.sh 2>&1 | tail -20`
Expected: `dist/Lume.app` produced and installed (script prints the install path). No build errors.

- [ ] **Step 2: Launch pointed at a test folder**

Prepare a scratch folder with a dotfile, then launch:

```bash
mkdir -p /tmp/lume-hidden-test/sub && printf 'x' > /tmp/lume-hidden-test/sub/a.md && printf 'SECRET=1' > /tmp/lume-hidden-test/.env
open -a Lume --env LUME_OPEN_FOLDER=/tmp/lume-hidden-test
```

(If `--env` is unavailable, launch via `LUME_OPEN_FOLDER=/tmp/lume-hidden-test open -n dist/Lume.app`.)

- [ ] **Step 3: Verify acceptance criteria (a)–(e) from the spec**

Drive the app and confirm each — screenshot or note the result for each line:

- (a) **Pinned expand shows files AND folders.** Pin a folder, expand it inline in FAVORITES → both files and subfolders appear.
- (b) **Hide scope is Favorites-only.** Select nested item(s) in a pinned folder → right-click → **Hide**. They vanish from FAVORITES. Browse the same real folder in OPEN FOLDER → the same items are STILL visible (and not dimmed).
- (c) **FAVORITES eye reveals + un-hide restores.** Click the eye in the FAVORITES header → hidden items reappear dimmed with an inline un-hide eye. Click un-hide (or toggle the header eye off then Hide again) → item returns to normal/hidden as expected.
- (d) **OPEN FOLDER eye is independent.** Click the eye in the OPEN FOLDER header → `.env` (and other dotfiles) appear/disappear. Confirm this does NOT change what the FAVORITES eye shows, and vice-versa.
- (e) **Menu gating.** Right-click in OPEN FOLDER → **no Hide item**, Pin/Unpin present. Right-click a top-level favorite → **Unpin** present, no Hide. Right-click a nested item inside a pinned folder → **Hide/Un-hide** present, no Unpin.

- [ ] **Step 4: Confirm persistence**

Toggle both eyes on, quit and relaunch the app (`open -a Lume`). Expected: both toggles restore their state (`lume.showPinnedHidden` / `lume.showBrowserHidden` persisted).

- [ ] **Step 5: Record outcome**

If every check passes, the feature is done. If any check fails, capture the exact symptom and fix via `superpowers:systematic-debugging` before re-running this task. Do not mark complete until (a)–(e) and Step 4 all pass.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Decision 1 (Hide scope = pinned only) → Task 3 Step 3 (filter only `.pinned`), Task 4 (Hide only nested pinned). ✓
- Decision 2 (two controls, one per region, not top bar) → Task 2 Steps 2–5. ✓
- Decision 3 (hidable = files and folders; multi-select Hide) → Task 4 Step 1 acts on selection regardless of `isDirectory`. ✓
- Decision 4 (`FileMeta.hidden` meaning narrows, no schema change) → no model/schema task; `LibraryStore` untouched per spec §1. ✓
- Decision 5 (`Files only` unchanged) → Task 2 Step 2 keeps it. ✓
- Design §2 (two persisted flags, abandon old key) → Task 1. ✓
- Design §3 (section-header eye toggles, shared helper) → Task 2 Steps 3–5. ✓
- Design §4 pinned/browser behavior, seed/reload/onChange → Task 3 Steps 1–6. ✓
- Design §5 (RowMenu gating) → Task 4. ✓
- Testing §(a)–(e) → Task 5 Step 3. ✓
- Out-of-scope items respected (no dotfile reveal inside pinned: Task 3 forces `includeHidden:false` for `.pinned`; no `Files only`/tags/Copy Paths changes). ✓

**Placeholder scan:** none — every code step shows the exact before/after.

**Type consistency:** `showPinnedHidden`/`showBrowserHidden` (Task 1) used identically in Tasks 2–3. `SectionHeader(title:isOn:help:)` defined in Task 2 Step 3, called with matching labels in Steps 4–5. `model.isPinned(url)`, `model.unpinSelection()`, `model.togglePin(_:isDirectory:)`, `model.setHiddenForSelection(_:)`, `model.selectionIsAllHidden(_:)`, `model.unhide(_:)` all exist in AppModel as read. ✓
