# Display Names v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sidebar disambiguate recurring filenames (many `.env`, many `CLAUDE.md`) by showing an auto parent-folder name in the Pinned list, while always keeping the real filename visible (muted) beside the label.

**Architecture:** A pure `DisplayName.autoName(for:)` function in `LumeCore` derives the parent-folder name for a curated set of ambiguous filenames. The auto-name is computed at render time and **never persisted** — `FileMeta.displayName` keeps storing only user overrides. The Pinned section applies the auto-name; the Browser does not (the folder is already visible in the tree). A file row renders `EffectiveName + muted filename` whenever the two differ.

**Tech Stack:** Swift 6, Swift Package Manager (no Xcode project), SwiftUI, SwiftData, Swift Testing.

**Design source:** `docs/superpowers/specs/2026-06-03-display-names-v2-design.md` (approved).

**Build/test prefix (CRITICAL):** the active CLT toolchain lacks the SwiftData macro plugin, so every swift command MUST be prefixed:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build|test`.

---

## File Structure

- **Create** `Sources/LumeCore/DisplayName.swift` — pure logic: the curated ambiguous-name predicate + `autoName(for:)`. No SwiftUI/SwiftData deps.
- **Create** `Tests/LumeCoreTests/DisplayNameTests.swift` — unit tests for every curated pattern, case-insensitivity, `.env.*`, non-matches, parent extraction, and filesystem-root edge.
- **Modify** `Sources/LumeApp/Sidebar/FileTreeView.swift` — `FileRow` renders effective name + muted filename; `SidebarItemRow` passes a context-derived auto-name; `RenameField` pre-fill + clear logic per §4.

**Decision (deviation from the design's "Architecture & Files" note):** the design suggested computing the auto-name in `SidebarView` and threading it down. Instead we compute it inside `SidebarItemRow`/`RenameField` from the `section` they already hold (`.pinned` → apply auto-name, `.browser` → `nil`). This is DRYer and avoids threading a value through the recursive `FileTreeView`. **`SidebarView.swift` therefore needs no change.** Net behavior is identical to the spec.

No new persisted fields; no SwiftData migration.

---

## Task 1: `DisplayName.autoName` (LumeCore, pure, TDD)

**Files:**
- Create: `Sources/LumeCore/DisplayName.swift`
- Test: `Tests/LumeCoreTests/DisplayNameTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LumeCoreTests/DisplayNameTests.swift` (free `@Test` functions to match `EnvFileTests.swift` style; all names prefixed `displayName_` so a single `--filter` selects them):

```swift
import Testing
import Foundation
@testable import LumeCore

// MARK: isAmbiguous

@Test func displayName_isAmbiguousMatchesCuratedExactNames() {
    for n in ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "README.md",
              "index.html", "index.md", "package.json", "Dockerfile",
              "docker-compose.yml", "Makefile", ".gitignore"] {
        #expect(DisplayName.isAmbiguous(n), "\(n) should be ambiguous")
    }
}

@Test func displayName_isAmbiguousIsCaseInsensitive() {
    #expect(DisplayName.isAmbiguous("claude.md"))
    #expect(DisplayName.isAmbiguous("ReadMe.MD"))
    #expect(DisplayName.isAmbiguous("DOCKERFILE"))
}

@Test func displayName_isAmbiguousMatchesEnvAndEnvVariants() {
    #expect(DisplayName.isAmbiguous(".env"))
    #expect(DisplayName.isAmbiguous(".env.local"))
    #expect(DisplayName.isAmbiguous(".env.production"))
    #expect(DisplayName.isAmbiguous(".ENV"))
}

@Test func displayName_isAmbiguousRejectsNonMatches() {
    #expect(!DisplayName.isAmbiguous("notes.md"))
    #expect(!DisplayName.isAmbiguous("main.swift"))
    #expect(!DisplayName.isAmbiguous("environment"))   // no leading dot
    #expect(!DisplayName.isAmbiguous(".environment"))  // ".env." prefix requires the trailing dot
    #expect(!DisplayName.isAmbiguous("README.txt"))
}

// MARK: autoName

@Test func displayName_autoNameReturnsParentFolderForAmbiguousFile() {
    let url = URL(fileURLWithPath: "/Users/me/freshydeli/.env")
    #expect(DisplayName.autoName(for: url) == "freshydeli")
}

@Test func displayName_autoNameWorksForEnvVariantAndDeepPath() {
    let url = URL(fileURLWithPath: "/Users/me/projects/cara/.env.local")
    #expect(DisplayName.autoName(for: url) == "cara")
}

@Test func displayName_autoNameIsNilForNonAmbiguousFile() {
    let url = URL(fileURLWithPath: "/Users/me/freshydeli/notes.md")
    #expect(DisplayName.autoName(for: url) == nil)
}

@Test func displayName_autoNameAtFilesystemRootReturnsRoot() {
    // Edge: ambiguous file directly at "/" — parent is "/", documents the behavior.
    #expect(DisplayName.autoName(for: URL(fileURLWithPath: "/CLAUDE.md")) == "/")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter displayName_`
Expected: FAIL — compile error, `cannot find 'DisplayName' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/LumeCore/DisplayName.swift`:

```swift
import Foundation

/// Display-only naming helper. Derives a parent-folder label for a curated set
/// of recurring, ambiguous filenames (many `.env`, many `CLAUDE.md`) so Pinned
/// rows are distinguishable at a glance. Pure logic — never touches the file
/// system or SwiftData, and never renames anything on disk.
public enum DisplayName {

    /// Basenames (lowercased) that are too generic to identify on their own.
    /// `.env` / `.env.*` are handled separately by prefix.
    private static let ambiguousNames: Set<String> = [
        "claude.md", "agents.md", "gemini.md", "readme.md",
        "index.html", "index.md", "package.json", "dockerfile",
        "docker-compose.yml", "makefile", ".gitignore",
    ]

    /// True when `filename` is one of the curated ambiguous names, matched
    /// case-insensitively. Also matches `.env` and any `.env.*` variant
    /// (e.g. `.env.local`, `.env.production`).
    public static func isAmbiguous(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        return ambiguousNames.contains(lower)
    }

    /// The parent-folder name to show in place of an ambiguous filename, or
    /// `nil` when the file isn't ambiguous (caller should fall back to the
    /// filename). Computed at render time; never persisted.
    public static func autoName(for url: URL) -> String? {
        guard isAmbiguous(url.lastPathComponent) else { return nil }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter displayName_`
Expected: PASS — all 8 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeCore/DisplayName.swift Tests/LumeCoreTests/DisplayNameTests.swift
git commit -m "feat(core): add DisplayName.autoName for ambiguous filenames"
```

---

## Task 2: FileRow renders effective name + muted filename

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (`FileRow` struct, lines 104-142; `SidebarItemRow` FileRow call, lines 81-85)

App-layer view rendering has no unit tests in this project (see design §Testing) — it is verified by building and driving the app in Task 4. Each step here is still atomic so the build stays green.

- [ ] **Step 1: Add `autoName` to `FileRow` and render the muted filename**

Replace the `FileRow` struct body (currently lines 104-118) with:

```swift
/// A leaf file row: kind-tinted icon + effective name, with the real filename
/// shown muted alongside whenever the label differs from it.
struct FileRow: View {
    let url: URL
    let kind: FileKind
    var name: String? = nil       // user override (FileMeta.displayName), if any
    var autoName: String? = nil   // parent-folder auto-name (Pinned context only)

    /// Override > auto-name > real filename.
    private var effectiveName: String { name ?? autoName ?? url.lastPathComponent }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(effectiveName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if effectiveName != url.lastPathComponent {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)   // give up space first when the row is tight
                }
            }
        } icon: {
            Image(systemName: icon(for: kind))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(for: kind))
        }
    }
```

(Leave the `icon(for:)` and `tint(for:)` methods, lines 120-141, unchanged.)

- [ ] **Step 2: Pass the context-derived auto-name from `SidebarItemRow`**

In `SidebarItemRow.body`, replace the file branch (currently lines 81-85):

```swift
                } else {
                    FileRow(url: url,
                            kind: FileKind.detect(filename: url.lastPathComponent),
                            name: names[url.path])
                }
```

with:

```swift
                } else {
                    FileRow(url: url,
                            kind: FileKind.detect(filename: url.lastPathComponent),
                            name: names[url.path],
                            autoName: section == .pinned ? DisplayName.autoName(for: url) : nil)
                }
```

(`LumeCore` is already imported at the top of the file, so `DisplayName` resolves.)

- [ ] **Step 3: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): show parent-folder auto-name + muted filename in pinned rows"
```

---

## Task 3: RenameField pre-fill + clear via auto-name

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (`RenameField` struct, lines 174-207; `SidebarItemRow` RenameField call, line 75)

- [ ] **Step 1: Pass the context-derived auto-name into `RenameField`**

In `SidebarItemRow.body`, replace the renaming branch (currently line 75):

```swift
                if isRenaming {
                    RenameField(url: url, model: model)
                } else if isDirectory {
```

with:

```swift
                if isRenaming {
                    RenameField(url: url, model: model,
                                autoName: section == .pinned ? DisplayName.autoName(for: url) : nil)
                } else if isDirectory {
```

- [ ] **Step 2: Pre-fill with the effective label and clear-to-default on commit**

Replace the entire `RenameField` struct (currently lines 174-207) with:

```swift
/// In-place display-name editor shown on the row being renamed. Pre-fills with
/// the effective label and treats "filename" or "auto-name" as "no override".
struct RenameField: View {
    let url: URL
    let model: AppModel
    var autoName: String? = nil   // Pinned-context parent-folder name, if applicable

    @Environment(\.modelContext) private var context
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                // Effective label: user override > auto-name (pinned) > filename.
                text = model.store?.displayName(for: url.path)
                    ?? autoName
                    ?? url.lastPathComponent
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { model.renamingPath = nil }   // Esc cancels
            .onChange(of: focused) { _, f in if !f && model.renamingPath == url.path { commit() } }
    }

    private func commit() {
        let store = LibraryStore(context: context)
        let meta = store.meta(for: url.path)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Accepting the real filename OR the auto-name stores no override, so the
        // row stays auto/plain and a later auto-name change still applies.
        let isDefault = trimmed == url.lastPathComponent || trimmed == autoName
        // Preserve existing notes/tags; only the display name changes here.
        store.setMeta(path: url.path,
                      info: meta?.info ?? "",
                      tagNames: meta?.tags.map(\.name) ?? [],
                      displayName: isDefault ? "" : trimmed)
        model.renamingPath = nil
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/LumeApp/Sidebar/FileTreeView.swift
git commit -m "feat(app): rename pre-fills effective label, clears to auto-default"
```

---

## Task 4: Full build, regression tests, and manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full LumeCore test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS — the existing suite plus the 8 new `displayName_` tests, all green.

- [ ] **Step 2: Build the app**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!`

- [ ] **Step 3: Launch against a folder with ambiguous files and verify behavior**

Run (point at a folder tree containing several `.env` / `CLAUDE.md` under different parents):

```bash
LUME_OPEN_FOLDER="$HOME/Developer" .build/debug/LumeApp
```

Confirm, by interacting with the app (screenshots are unavailable — Screen Recording isn't granted to the terminal; verify by direct observation):

- A **pinned** `.env` shows its **parent folder name** as the label with a muted `.env` trailing on the same line.
- The **same** `.env` shown in the **Browser** tree shows a plain `.env` (no auto-name, no muted reference).
- A pinned non-ambiguous file (e.g. `notes.md`) shows just its filename, no muted reference.
- **Rename** a pinned `.env`: the editor pre-fills with the parent-folder name (not blank, not `.env`). Type a custom string → it persists and shows as the label with muted `.env` trailing.
- **Clear** the custom name (or retype the parent-folder name) and commit → the row reverts to the parent-folder auto-name (no stored override). Retyping exactly `.env` also stores nothing (plain auto-default).
- Folders are unchanged — no auto-name, no muted reference.

- [ ] **Step 4: Confirm completion**

REQUIRED SUB-SKILL: Use superpowers:verification-before-completion before claiming done — paste the actual `swift test` summary line and the `Build complete!` line as evidence.

---

## Self-Review (completed during authoring)

- **Spec coverage:** §1 auto-name rule → Task 1; §2 per-context effective label (pinned applies auto-name, browser doesn't; muted filename when differs; folders unchanged) → Task 2; §3 visual treatment (caption, `.secondary`, filename truncates first via `layoutPriority(-1)`, shown only when differs) → Task 2; §4 editing (pre-fill effective, commit stores `""` when text == filename or == auto-name) → Task 3. All covered.
- **Deviation noted:** auto-name computed in `SidebarItemRow`/`RenameField` from `section` rather than in `SidebarView`; `SidebarView.swift` unchanged. Behavior identical to spec.
- **Type consistency:** `DisplayName.autoName(for:)` / `DisplayName.isAmbiguous(_:)` used consistently across tasks; `FileRow.autoName` and `RenameField.autoName` are both `String?`; `LibraryStore.setMeta(path:info:tagNames:displayName:)` and `displayName(for:)` / `meta(for:)` match the existing store API.
- **No placeholders:** every code/test step shows complete content; every run step shows the exact command and expected output.
