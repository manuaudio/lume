# All-Encompassing Favorites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pin SSH and GitHub items into the same Favorites list as local files, each remote item carrying a source badge; clicking a remote favorite connects to its source (if needed) and opens it.

**Architecture:** A new additive `RemoteFavorite` SwiftData model (separate from the local-URL-coupled `Favorite`) lands behind an explicit `LumeSchemaV2` + a `.lightweight` migration stage — the "next schema change" the existing schema code anticipates. `LibraryStore` gains remote-favorite CRUD; `AppState` merges `[Favorite]` + `[RemoteFavorite]` into one ordered sidebar list and routes a remote-favorite click through the existing `connectSSH`/`connectGitHub` lifecycle. Local favorites render and expand exactly as today; remote favorites are leaf jump-points.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, SwiftData (versioned schema + migration plan), Swift Testing (`import Testing`, `#expect`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-06-15-all-encompassing-favorites-design.md`

**Documented deviations from the spec** (flag to the user if they object):
1. *Reorder UI:* the spec mentions drag-reorder across the merged list. Favorites have **no existing drag-reorder UI** today (`reorderFavorites` is store+test only; no `.onMove` anywhere in the sidebar). This plan ships `reorderAllFavorites` as a store-level capability with a unit test, but does **not** add a new sidebar drag-reorder gesture — there's no existing pattern to extend, and adding one is a separable UI concern. New favorites (local or remote) append at the end by `sortIndex`, matching today's behavior.
2. *Remote folder favorites:* clicking one reroots the remote tree to that path (no inline expansion in the Favorites region), exactly as the spec's non-goals state.
3. *Pin entry point:* the spec mentions pinning from both the remote tree rows and the open-file toolbar. This plan ships the **tree-row context menu** only (mirrors how local rows expose "Add to Favorites" via their context menu). The remote detail pane has no existing actions toolbar to extend, so a toolbar pin button is deferred — the context menu fully covers pinning a remote file or folder.

**Build/test commands** (run from repo root):

```bash
# After ANY task that creates a new .swift file, regenerate the project first:
xcodegen generate

# Run one test suite:
xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:'LumeKitTests/<SuiteName>' 2>&1 | tail -20

# Full build + all tests:
xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' \
  -derivedDataPath build 2>&1 | tail -20
```

---

### Task 1: `RemoteFavorite` model + `LumeSchemaV2` + lightweight migration

**Files:**
- Modify: `Sources/LumeKit/Library/Models.swift` (add the model)
- Modify: `Sources/LumeKit/Library/LumeSchema.swift` (V2 + stage)
- Modify: `Sources/LumeKit/Library/LibraryContainerFactory.swift` (use V2)
- Modify: `Tests/LumeKitTests/LibraryTestSupport.swift` (`makeLibrary` → V2)
- Modify: `Tests/LumeKitTests/LumeSchemaTests.swift` (V2 coverage + migration regression)

- [ ] **Step 1: Write the failing tests**

Replace the body of `Tests/LumeKitTests/LumeSchemaTests.swift` with:

```swift
import Testing
import SwiftData
import Foundation
@testable import LumeKit

@MainActor @Test func v1SchemaCoversOriginalSixModels() throws {
    #expect(LumeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    let names = Set(Schema(versionedSchema: LumeSchemaV1.self).entities.map(\.name))
    #expect(names == ["Favorite", "Bookmark", "Tag", "FileMeta", "Scan", "ContextBundle"])
}

@MainActor @Test func v2SchemaAddsRemoteFavorite() throws {
    #expect(LumeSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    let names = Set(Schema(versionedSchema: LumeSchemaV2.self).entities.map(\.name))
    #expect(names == ["Favorite", "Bookmark", "Tag", "FileMeta", "Scan", "ContextBundle", "RemoteFavorite"])
}

@MainActor @Test func containerOpensAtV2WithMigrationPlan() throws {
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV2.self),
        migrationPlan: LumeMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext
    context.insert(Favorite(path: "/f", kindRaw: "markdown"))
    context.insert(RemoteFavorite(ref: "ssh:web1:/etc/x", sourceKindRaw: "ssh",
                                  sourceKey: "web1", path: "/etc/x", isDirectory: false))
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<RemoteFavorite>()).count == 1)
}

/// The critical safety test: a store written under V1 (local favorites only)
/// must open under V2 with its data intact and the new table usable.
@MainActor @Test func v1StoreMigratesToV2WithoutDataLoss() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumeMigrationTest-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: url) }

    // 1) Write a V1 store with one favorite, then tear the container down.
    do {
        let v1 = try ModelContainer(
            for: Schema(versionedSchema: LumeSchemaV1.self),
            configurations: [ModelConfiguration(schema: Schema(versionedSchema: LumeSchemaV1.self), url: url)]
        )
        v1.mainContext.insert(Favorite(path: "/kept.md", kindRaw: "markdown"))
        try v1.mainContext.save()
        withExtendedLifetime(v1) {}
    }

    // 2) Reopen the same file under V2 + the migration plan.
    let v2 = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV2.self),
        migrationPlan: LumeMigrationPlan.self,
        configurations: [ModelConfiguration(schema: Schema(versionedSchema: LumeSchemaV2.self), url: url)]
    )
    defer { withExtendedLifetime(v2) {} }
    let favs = try v2.mainContext.fetch(FetchDescriptor<Favorite>())
    #expect(favs.map(\.path) == ["/kept.md"])               // local data survived
    v2.mainContext.insert(RemoteFavorite(ref: "github:o/r:/a.md", sourceKindRaw: "github",
                                         sourceKey: "o/r", path: "/a.md", isDirectory: false))
    try v2.mainContext.save()
    #expect(try v2.mainContext.fetch(FetchDescriptor<RemoteFavorite>()).count == 1)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test ... -only-testing:'LumeKitTests/LumeSchemaTests'`
Expected: BUILD FAILS — `cannot find 'RemoteFavorite' in scope` / `cannot find 'LumeSchemaV2'`.

- [ ] **Step 3: Add the `RemoteFavorite` model**

Append to `Sources/LumeKit/Library/Models.swift`:

```swift
/// A favorite that lives on a remote source (SSH host or GitHub repo). Kept in
/// its own table — not folded into `Favorite` — because `Favorite.path` is the
/// unique key and is interpreted as a LOCAL filesystem path throughout the
/// favorites renderer, and two hosts can legitimately pin the same path string.
/// `ref` is the dedup key; the component fields are stored separately so nothing
/// has to parse `ref` back.
@Model public final class RemoteFavorite {
    @Attribute(.unique) public var ref: String   // "ssh:web1:/etc/x" | "github:owner/repo:/docs/a.md"
    public var sourceKindRaw: String              // "ssh" | "github"
    public var sourceKey: String                  // host alias | repo slug
    public var path: String                       // remote path
    public var isDirectory: Bool                  // folder → reroot tree; file → open
    public var dateAdded: Date
    /// Shared ordering space with `Favorite.sortIndex` (the merged sidebar list).
    public var sortIndex: Int

    public init(ref: String, sourceKindRaw: String, sourceKey: String, path: String,
                isDirectory: Bool, dateAdded: Date = .now, sortIndex: Int = 0) {
        self.ref = ref
        self.sourceKindRaw = sourceKindRaw
        self.sourceKey = sourceKey
        self.path = path
        self.isDirectory = isDirectory
        self.dateAdded = dateAdded
        self.sortIndex = sortIndex
    }
}
```

- [ ] **Step 4: Add `LumeSchemaV2` + the migration stage**

Replace `Sources/LumeKit/Library/LumeSchema.swift` with:

```swift
import SwiftData

/// Versioned snapshot of the store layout (audit A3b). ALL container creation
/// (app + tests) goes through this so any model change is an explicit schema
/// version + migration stage, never implicit lightweight migration
/// (Models.swift documents prior launch crashes from exactly that).
public enum LumeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self, ContextBundle.self]
    }
}

/// V2 adds `RemoteFavorite` (all-encompassing favorites). Pure addition of a new
/// entity, so the V1→V2 stage is lightweight: no existing row is transformed and
/// the new table starts empty. Vestigial `Bookmark` stays for now (deferred drop).
public enum LumeSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self,
         ContextBundle.self, RemoteFavorite.self]
    }
}

public enum LumeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [LumeSchemaV1.self, LumeSchemaV2.self]
    }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LumeSchemaV1.self, toVersion: LumeSchemaV2.self)]
    }
}
```

- [ ] **Step 5: Point the container factory at V2**

In `Sources/LumeKit/Library/LibraryContainerFactory.swift`, line 28, change:

```swift
        let schema = Schema(versionedSchema: LumeSchemaV2.self)
```

(The three `ModelContainer(...)` calls already pass `migrationPlan: LumeMigrationPlan.self` — unchanged.)

- [ ] **Step 6: Point the test helper at V2**

In `Tests/LumeKitTests/LibraryTestSupport.swift`, change both `Schema(versionedSchema: LumeSchemaV1.self)` occurrences in `makeLibrary()` to `LumeSchemaV2.self`, and update the comment's "LumeSchemaV1" reference to "LumeSchemaV2".

- [ ] **Step 7: Run the schema suite + full suite**

Run: `xcodebuild test ... -only-testing:'LumeKitTests/LumeSchemaTests'` → PASS (4 tests).
Then the full suite → no regressions (every other LumeKit test opens via `makeLibrary`, now on V2).

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeKit/Library/ Tests/LumeKitTests/LumeSchemaTests.swift Tests/LumeKitTests/LibraryTestSupport.swift
git commit -m "feat: RemoteFavorite model + LumeSchemaV2 lightweight migration"
```

---
### Task 2: `LibraryStore` remote-favorite CRUD + `reorderAllFavorites`

**Files:**
- Modify: `Sources/LumeKit/Library/LibraryStore.swift`
- Test: `Tests/LumeKitTests/RemoteFavoriteStoreTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

`Tests/LumeKitTests/RemoteFavoriteStoreTests.swift`:

```swift
import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func addAndQueryRemoteFavorite() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    #expect(store.isRemoteFavorite(ref: "ssh:web1:/etc/x") == false)
    store.addRemoteFavorite(ref: "ssh:web1:/etc/x", sourceKind: "ssh",
                            sourceKey: "web1", path: "/etc/x", isDirectory: false)
    #expect(store.isRemoteFavorite(ref: "ssh:web1:/etc/x"))
    #expect(store.remoteFavorites().map(\.path) == ["/etc/x"])
}

@MainActor @Test func addRemoteFavoriteIsIdempotentOnRef() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addRemoteFavorite(ref: "github:o/r:/a.md", sourceKind: "github",
                            sourceKey: "o/r", path: "/a.md", isDirectory: false)
    store.addRemoteFavorite(ref: "github:o/r:/a.md", sourceKind: "github",
                            sourceKey: "o/r", path: "/a.md", isDirectory: false)
    #expect(store.remoteFavorites().count == 1)
}

@MainActor @Test func removeRemoteFavorite() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addRemoteFavorite(ref: "ssh:web1:/a", sourceKind: "ssh",
                            sourceKey: "web1", path: "/a", isDirectory: true)
    store.removeRemoteFavorite(ref: "ssh:web1:/a")
    #expect(store.remoteFavorites().isEmpty)
}

@MainActor @Test func twoHostsSamePathAreDistinct() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addRemoteFavorite(ref: "ssh:web1:/etc/nginx.conf", sourceKind: "ssh",
                            sourceKey: "web1", path: "/etc/nginx.conf", isDirectory: false)
    store.addRemoteFavorite(ref: "ssh:web2:/etc/nginx.conf", sourceKind: "ssh",
                            sourceKey: "web2", path: "/etc/nginx.conf", isDirectory: false)
    #expect(store.remoteFavorites().count == 2)
}

@MainActor @Test func reorderAllFavoritesRewritesSharedSortIndex() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addFavorite(path: "/local.md", kind: .markdown)                  // sortIndex 0
    store.addRemoteFavorite(ref: "ssh:web1:/r", sourceKind: "ssh",
                            sourceKey: "web1", path: "/r", isDirectory: false)  // sortIndex 0 in its table
    // Interleave: remote first, then local.
    store.reorderAllFavorites([.remote(ref: "ssh:web1:/r"), .local(path: "/local.md")])
    #expect(store.remoteFavorites().first?.sortIndex == 0)
    #expect(store.favorites().first?.sortIndex == 1)
}
```

- [ ] **Step 2: Run to verify failure** — `value of type 'LibraryStore' has no member 'addRemoteFavorite'` / `cannot find 'FavoriteRef'`.

- [ ] **Step 3: Add the CRUD + reorder + `FavoriteRef`**

In `Sources/LumeKit/Library/LibraryStore.swift`, immediately after the `favorite(for:)` private method (line ~94), add:

```swift
    // MARK: Remote favorites (SSH / GitHub)

    public func addRemoteFavorite(ref: String, sourceKind: String, sourceKey: String,
                                  path: String, isDirectory: Bool) {
        if remoteFavorite(for: ref) != nil { return }
        let order = favorites().count + remoteFavorites().count
        context.insert(RemoteFavorite(ref: ref, sourceKindRaw: sourceKind, sourceKey: sourceKey,
                                      path: path, isDirectory: isDirectory, sortIndex: order))
        save("addRemoteFavorite")
    }

    public func removeRemoteFavorite(ref: String) {
        if let fav = remoteFavorite(for: ref) { context.delete(fav); save("removeRemoteFavorite") }
    }

    public func isRemoteFavorite(ref: String) -> Bool {
        remoteFavorite(for: ref) != nil
    }

    public func remoteFavorites() -> [RemoteFavorite] {
        (try? context.fetch(
            FetchDescriptor<RemoteFavorite>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    private func remoteFavorite(for ref: String) -> RemoteFavorite? {
        var d = FetchDescriptor<RemoteFavorite>(predicate: #Predicate { $0.ref == ref })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// Rewrite the single shared `sortIndex` space across BOTH favorite tables so
    /// local and remote rows interleave in the given order (drag-reorder backing).
    public func reorderAllFavorites(_ ordered: [FavoriteRef]) {
        for (i, item) in ordered.enumerated() {
            switch item {
            case .local(let path): favorite(for: path)?.sortIndex = i
            case .remote(let ref): remoteFavorite(for: ref)?.sortIndex = i
            }
        }
        save("reorderAllFavorites")
    }
```

Add this value type at the bottom of `Sources/LumeKit/Library/LibraryStore.swift`, after the class's closing brace:

```swift
/// One row's identity in the merged Favorites list — a local path or a remote
/// favorite `ref`. Used by `reorderAllFavorites`.
public enum FavoriteRef: Hashable, Sendable {
    case local(path: String)
    case remote(ref: String)
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (5 tests). Then the full suite — no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Library/LibraryStore.swift Tests/LumeKitTests/RemoteFavoriteStoreTests.swift
git commit -m "feat: LibraryStore remote-favorite CRUD + reorderAllFavorites"
```

---

### Task 3: AppState — merged list, pin/open logic, connect-then-open

**Files:**
- Modify: `Sources/Lume/AppState.swift`

No app-target test bundle; the gate is a clean build + the full LumeKit suite staying green (same convention as the SSH/GitHub UI tasks).

- [ ] **Step 1: Add the remote-favorites projection**

In `AppState.swift`, beside `private(set) var favorites: [Favorite] = []` (line ~127), add:

```swift
    private(set) var remoteFavorites: [RemoteFavorite] = []
```

In `refreshLibrary()` (line ~284), after `favorites = library.favorites()`, add:

```swift
        remoteFavorites = library.remoteFavorites()
```

- [ ] **Step 2: Add the merged row model + builder**

In the `// MARK: - Favorites (pinning)` section, after the existing `favoriteRowItems` computed property (ends line ~537), add:

```swift
    /// A row in the MERGED Favorites list: a local row (pin root or expanded
    /// child, unchanged behavior) or a remote favorite (leaf jump-point).
    enum FavoriteRow: Identifiable {
        case local(FavoriteRowItem)
        case remote(RemoteFavorite)
        var id: String {
            switch self {
            case .local(let i): return "L:\(i.id)"
            case .remote(let r): return "R:\(r.ref)"
            }
        }
    }

    /// Top-level ordering token so local pin roots and remote favorites
    /// interleave by their shared `sortIndex`.
    private enum FavoriteTop {
        case local(Favorite)
        case remote(RemoteFavorite)
        var sortIndex: Int {
            switch self {
            case .local(let f): return f.sortIndex
            case .remote(let r): return r.sortIndex
            }
        }
    }

    /// The merged Favorites rows: local pin roots (with their inline-expanded
    /// children, exactly as today) and remote favorites, interleaved by sortIndex.
    var mergedFavoriteRows: [FavoriteRow] {
        _ = cache.revision
        var tops: [FavoriteTop] =
            visibleFavorites.map(FavoriteTop.local) + remoteFavorites.map(FavoriteTop.remote)
        tops.sort { $0.sortIndex < $1.sortIndex }

        var out: [FavoriteRow] = []
        func walk(_ dir: URL, _ depth: Int) {
            for node in visiblePinnedChildren(of: dir) {
                out.append(.local(FavoriteRowItem(url: node.url, isDirectory: node.isDirectory,
                                                  depth: depth, isPinRoot: false)))
                if node.isDirectory, expandedFavorites.contains(node.url.path) {
                    walk(node.url, depth + 1)
                }
            }
        }
        for top in tops {
            switch top {
            case .local(let fav):
                let url = URL(fileURLWithPath: fav.path)
                let isDir = favoriteIsFolder(fav)
                out.append(.local(FavoriteRowItem(url: url, isDirectory: isDir, depth: 0, isPinRoot: true)))
                if isDir, expandedFavorites.contains(fav.path) { walk(url, 1) }
            case .remote(let r):
                out.append(.remote(r))
            }
        }
        return out
    }
```

- [ ] **Step 3: Add the remote pin/open API**

At the end of the `// MARK: - Favorites (pinning)` section, add:

```swift
    /// (kind, key, ref) for a path on the ACTIVE remote source, or nil if no
    /// remote source is active. `ref` is the dedup key the store stores.
    private func remoteRefComponents(path: String) -> (kind: String, key: String, ref: String)? {
        guard let id = remote?.sourceID else { return nil }
        switch id {
        case .ssh(let alias):  return ("ssh", alias, "ssh:\(alias):\(path)")
        case .github(let slug): return ("github", slug, "github:\(slug):\(path)")
        case .local: return nil
        }
    }

    func isRemoteFavorite(_ node: ResourceNode) -> Bool {
        guard let library, let c = remoteRefComponents(path: node.ref.path) else { return false }
        return library.isRemoteFavorite(ref: c.ref)
    }

    /// Pin/unpin a remote tree node to the global Favorites list.
    func toggleRemoteFavorite(_ node: ResourceNode) {
        guard let library, let c = remoteRefComponents(path: node.ref.path) else { return }
        if library.isRemoteFavorite(ref: c.ref) {
            library.removeRemoteFavorite(ref: c.ref)
        } else {
            library.addRemoteFavorite(ref: c.ref, sourceKind: c.kind, sourceKey: c.key,
                                      path: node.ref.path, isDirectory: node.isDirectory)
        }
        refreshLibrary()
    }

    /// Unpin a remote favorite directly (from its sidebar row).
    func removeRemoteFavorite(_ fav: RemoteFavorite) {
        library?.removeRemoteFavorite(ref: fav.ref)
        refreshLibrary()
    }

    /// Open a remote favorite: connect to its source if needed, then open the
    /// file (or reroot the tree for a folder). Reuses the SSH/GitHub lifecycle.
    func openRemoteFavorite(_ fav: RemoteFavorite) {
        let open: () -> Void = { [weak self] in
            guard let self else { return }
            if fav.isDirectory {
                Task { await self.remote?.reroot(to: fav.path) }
            } else {
                self.chooseRemote(fav.path)
            }
        }
        switch fav.sourceKindRaw {
        case "ssh":
            connectSSH(SSHHost(alias: fav.sourceKey), onReady: open)
        case "github":
            guard let ref = GitHubRepoRef(parsing: fav.sourceKey) else {
                showNotice("Can't open favorite: invalid repo \(fav.sourceKey).")
                return
            }
            connectGitHub(ref, onReady: open)
        default:
            break
        }
    }
```

- [ ] **Step 4: Thread `onReady` through the connect methods**

In `connectSSH` (line ~1441), change the signature and BOTH the early-return reconnect branch and the final connect Task:

```swift
    func connectSSH(_ host: SSHHost, onReady: (() -> Void)? = nil) {
        // Reconnecting to the already-active host just brings its tree back.
        if let remote, remote.sourceID == .ssh(alias: host.alias) {
            showRemoteSource()
            if case .failed = remote.phase {
                Task { await remote.connect(); if remote.phase == .ready { onReady?() } }
            } else {
                onReady?()
            }
            return
        }
        let previous = remote
        Task { await previous?.disconnect() }
        let connection = SSHConnection(
            host: host,
            startPath: connections.state.hostState[host.alias]?.lastPath)
        let session = RemoteSession(connection: connection, source: connection.source)
        remote = session
        showingRemote = true
        clearDocumentSelection()
        connections.noteConnected(alias: host.alias)
        Task { await session.connect(); if session.phase == .ready { onReady?() } }
    }
```

In `connectGitHub` (line ~1471 in the GitHub-lifecycle section), apply the identical pattern — add `onReady: (() -> Void)? = nil`, and in both the already-active branch and the final `Task { await session.connect() }` chain `if <session>.phase == .ready { onReady?() }`:

```swift
    func connectGitHub(_ ref: GitHubRepoRef, onReady: (() -> Void)? = nil) {
        if let remote, remote.sourceID == .github(slug: ref.slug) {
            showRemoteSource()
            if case .failed = remote.phase {
                Task { await remote.connect(); if remote.phase == .ready { onReady?() } }
            } else {
                onReady?()
            }
            return
        }
        let previous = remote
        Task { await previous?.disconnect() }
        let repoState = connections.state.githubRepos[ref.slug]
        let connection = GitHubConnection(
            ref: ref,
            client: githubClient,
            preferredBranch: repoState?.lastBranch,
            startPath: repoState?.lastPath)
        let session = RemoteSession(connection: connection, source: connection.source)
        remote = session
        showingRemote = true
        clearDocumentSelection()
        connections.noteRepoConnected(slug: ref.slug)
        Task { await session.connect(); if session.phase == .ready { onReady?() } }
    }
```

(`RemoteSession.Phase` is `Equatable`, so `phase == .ready` compiles.)

- [ ] **Step 5: Build + full suite**

Run: `xcodegen generate && xcodebuild test ... 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED (no new behavior reachable until the UI lands in Task 4).

- [ ] **Step 6: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "feat: AppState merged favorites list + remote pin/open with connect-then-open"
```

---
### Task 4: Sidebar — render the merged list + remote pin affordance

**Files:**
- Modify: `Sources/Lume/SidebarView.swift` (FavoritesRegion → merged rows)
- Modify: `Sources/Lume/FileRowView.swift` (new `RemoteFavoriteRow`)
- Modify: `Sources/Lume/Remote/RemoteTreeView.swift` (pin context menu on tree rows)

No app-target tests; gate is a clean build + full suite, then a visual smoke check.

- [ ] **Step 1: Render the merged list in `FavoritesRegion`**

In `Sources/Lume/SidebarView.swift`, replace the `FavoritesRegion` body's `else` branch (currently `ForEach(items) { item in FavoriteRow(item: item) }`) and the `let items` line:

```swift
    var body: some View {
        Section("Favorites") {
            let rows = app.mergedFavoriteRows
            if rows.isEmpty {
                Text("Pin files and folders here — or drag them in")
                    .font(.callout)
                    .foregroundStyle(dropTargeted ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: URL.self) { urls, _ in
                        app.pinDropped(urls); return !urls.isEmpty
                    } isTargeted: { dropTargeted = $0 }
            } else {
                ForEach(rows) { row in
                    switch row {
                    case .local(let item): FavoriteRow(item: item)
                    case .remote(let fav): RemoteFavoriteRow(fav: fav)
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: Add `RemoteFavoriteRow`**

Append to `Sources/Lume/FileRowView.swift` (after `FavoriteRow`, before `RowLabel`):

```swift
/// A favorite that lives on a remote source — a leaf jump-point with a source
/// badge (⚡ host for SSH, branch icon + slug for GitHub). Clicking connects to
/// the source if needed, then opens the file (or reroots the tree for a folder).
struct RemoteFavoriteRow: View {
    let fav: RemoteFavorite
    @Environment(AppState.self) private var app

    private var badgeIcon: String {
        fav.sourceKindRaw == "github" ? "arrow.triangle.branch" : "bolt.horizontal"
    }
    private var filename: String { (fav.path as NSString).lastPathComponent }

    var body: some View {
        Button { app.openRemoteFavorite(fav) } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 12)   // align with local rows' chevron gutter
                Image(systemName: fav.isDirectory
                      ? "folder.fill"
                      : symbolName(for: FileKind.detect(filename: filename)))
                    .foregroundStyle(fav.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Label(fav.sourceKey, systemImage: badgeIcon)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Favorites") { app.removeRemoteFavorite(fav) }
        }
    }
}
```

- [ ] **Step 3: Add the pin affordance to remote tree rows**

In `Sources/Lume/Remote/RemoteTreeView.swift`, in `RemoteNodeRow.body`, add the same context menu to BOTH the directory `Button` and the file `Button` — after each `.buttonStyle(.plain)`:

```swift
                .contextMenu {
                    Button(app.isRemoteFavorite(node) ? "Remove from Favorites" : "Add to Favorites") {
                        app.toggleRemoteFavorite(node)
                    }
                }
```

(The directory branch's Button is the one wrapping `row(systemImage: "folder", …)`; the file branch's Button wraps `row(systemImage: node.isSymlink ? "link" : "doc", …)`. Both get the menu.)

- [ ] **Step 4: Build + full suite**

Run: `xcodegen generate && xcodebuild test ... 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lume/SidebarView.swift Sources/Lume/FileRowView.swift Sources/Lume/Remote/RemoteTreeView.swift
git commit -m "feat: render remote favorites in the merged list + pin from remote tree"
```

---

### Task 5: Manual checklist + README note

**Files:**
- Create: `docs/remote-favorites-manual-test-checklist.md`
- Modify: `README.md`

- [ ] **Step 1: Create `docs/remote-favorites-manual-test-checklist.md`**

```markdown
# All-Encompassing Favorites — Manual Test Checklist

Prereqs: one SSH host you can reach (or the localhost setup from
`docs/ssh-manual-test-checklist.md`) and one GitHub repo (`gh` signed in).

## Pin
1. [ ] Connect to an SSH host, right-click a remote file → "Add to Favorites".
2. [ ] Right-click a remote folder → "Add to Favorites".
3. [ ] Open a GitHub repo, right-click a file → "Add to Favorites".

## Merged list
4. [ ] Switch the source switcher to Local. The Favorites section shows the
       local favorites AND the SSH file/folder (⚡ + alias badge) AND the GitHub
       file (branch icon + slug badge), all in one list.
5. [ ] Each remote favorite shows the filename + its source badge + a pin glyph.

## Open from disconnected
6. [ ] From Local, click the SSH file favorite → connects to the host and opens
       the file in the editor.
7. [ ] Click the SSH folder favorite → connects and the remote tree reroots to
       that folder.
8. [ ] Click the GitHub favorite → connects to the repo (default/last branch)
       and opens the file.

## Unpin
9. [ ] Right-click a remote favorite → "Remove from Favorites"; it disappears.
10. [ ] Re-pin, then right-click the same item in the remote tree → the menu now
        reads "Remove from Favorites" (state reflects the pin).

## Stale source
11. [ ] Pin an SSH file, then make the host unreachable (e.g. wrong alias /
        stopped sshd). Click the favorite → a connect error shows in the header;
        the favorite STAYS in the list.
12. [ ] Pin a GitHub file, rename/delete the repo on github.com, click the
        favorite → "Repository not found"; the favorite stays.

## Persistence / migration
13. [ ] Quit and relaunch Lume → all favorites (local + remote) are still there.
14. [ ] (If testing an upgrade) launch over a pre-existing library → old local
        favorites are intact and remote pinning works (V1→V2 migration).
```

- [ ] **Step 2: Add a README note**

Append to the favorites/remote feature area of `README.md` (next to the SSH/GitHub blurbs):

```markdown
### One Favorites list for every source

Pin local files, SSH paths, and GitHub repo files into a single Favorites
list. Remote favorites carry a small source badge (⚡ host for SSH, branch icon
+ repo for GitHub); clicking one connects to its source if needed and opens the
file — or reroots the tree, for a pinned folder. Right-click any remote tree
row to Add/Remove from Favorites. Favorites persist locally (no server sync).
```

- [ ] **Step 3: Run the checklist** against a real host + repo. Record any failures as findings — do not mark this task complete with open failures.

- [ ] **Step 4: Final full suite**

Run: `xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -20`
Expected: TEST SUCCEEDED — all suites.

- [ ] **Step 5: Commit**

```bash
git add docs/remote-favorites-manual-test-checklist.md README.md
git commit -m "docs: all-encompassing favorites manual checklist + README note"
```


