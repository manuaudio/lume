# Cross-Machine Favorites Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync remote favorites (SSH/GitHub) and manual SSH connections across a user's own Macs via an iCloud JSON document, with tombstoned deletions and last-writer-wins merge.

**Architecture:** A pure `SyncDocument` value type is the wire format; a pure `SyncMerge.reconcile(baseline:local:incoming:now:)` three-way merge is the heart (fully unit-testable, no I/O). A `SyncDocumentStore` protocol abstracts reading/writing the document + baseline, with an iCloud-ubiquity implementation and an in-memory fake for tests. `FavoritesSyncEngine` (the thin I/O shell) projects local state from `LibraryStore`/`ConnectionStore`, runs the merge, applies the result back through existing store APIs (guarded against a feedback loop), and observes incoming changes via `NSMetadataQuery`. SwiftData stays the untouched local source of truth — no schema migration.

**Tech Stack:** Swift 6 (strict concurrency), Foundation (`NSFileCoordinator`, `NSMetadataQuery`, `FileManager` ubiquity), SwiftData (unchanged), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-06-17-favorites-sync-design.md`

**Documented deviations / constraints** (flag to the user if they object):
1. *Signing:* the repo builds ad-hoc-signed (`CODE_SIGN_IDENTITY: "-"`, no `.entitlements`). A real iCloud ubiquity container requires a provisioned Apple Developer profile. Under the repo's dev signing, `FileManager.url(forUbiquityContainerIdentifier:)` returns nil → the engine takes the spec's "iCloud unavailable → no-op" path. The entitlement + `project.yml` wiring (Task 5) is added so it activates once the app is signed with an iCloud-enabled profile, but it is **inert and untested in CI/dev**. All sync logic is validated via unit tests against the fake store; real cross-Mac propagation is manual-checklist-only and needs two iCloud-signed Macs.
2. *Order not synced:* `sortIndex` is excluded from the wire format (per spec). An applied favorite appends locally via `LibraryStore.addRemoteFavorite`'s existing ordering.
3. *No SwiftData migration:* timestamps/tombstones live only in the JSON + engine; `RemoteFavorite`/`SSHHost` models are untouched (no `LumeSchemaV3`).

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

### Task 1: `SyncDocument` + `SyncMerge.reconcile` (pure wire format + three-way merge)

**Files:**
- Create: `Sources/LumeKit/Sync/SyncDocument.swift`
- Create: `Sources/LumeKit/Sync/SyncMerge.swift`
- Test: `Tests/LumeKitTests/SyncMergeTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/LumeKitTests/SyncMergeTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeKit

struct SyncMergeTests {
    // Fixed clock points so timestamps are deterministic.
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)
    private let now = Date(timeIntervalSince1970: 3_000)

    private func fav(_ ref: String, path: String = "/p", dir: Bool = false,
                     at: Date, deleted: Bool = false) -> RemoteFavoriteRecord {
        let parts = ref.split(separator: ":", maxSplits: 2).map(String.init)
        return RemoteFavoriteRecord(ref: ref, sourceKind: parts[0], sourceKey: parts[1],
                                    path: path, isDirectory: dir, updatedAt: at, deleted: deleted)
    }
    private func doc(_ favs: [RemoteFavoriteRecord] = [], _ hosts: [ManualHostRecord] = []) -> SyncDocument {
        SyncDocument(schemaVersion: 1, remoteFavorites: favs, manualHosts: hosts)
    }

    @Test func newLocalItemAppearsStampedNow() {
        let out = SyncMerge.reconcile(baseline: doc(), local: doc([fav("ssh:w:/a", at: .distantPast)]),
                                      incoming: doc(), now: now)
        #expect(out.remoteFavorites.count == 1)
        #expect(out.remoteFavorites[0].updatedAt == now)
        #expect(out.remoteFavorites[0].deleted == false)
    }

    @Test func newIncomingItemAppears() {
        let out = SyncMerge.reconcile(baseline: doc(), local: doc(),
                                      incoming: doc([fav("ssh:w:/a", at: t2)]), now: now)
        #expect(out.remoteFavorites.map(\.ref) == ["ssh:w:/a"])
        #expect(out.remoteFavorites[0].updatedAt == t2)
    }

    @Test func unchangedItemKeepsBaselineTimestamp() {
        let b = doc([fav("ssh:w:/a", at: t1)])
        let out = SyncMerge.reconcile(baseline: b, local: doc([fav("ssh:w:/a", at: .distantPast)]),
                                      incoming: b, now: now)
        #expect(out.remoteFavorites[0].updatedAt == t1)   // not re-stamped
    }

    @Test func localEditBeatsOlderIncoming() {
        let b = doc([fav("ssh:w:/a", path: "/old", at: t1)])
        let local = doc([fav("ssh:w:/a", path: "/NEW", at: .distantPast)])    // path changed
        let incoming = doc([fav("ssh:w:/a", path: "/old", at: t1)])
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].path == "/NEW")
        #expect(out.remoteFavorites[0].updatedAt == now)
    }

    @Test func newerIncomingBeatsUnchangedLocal() {
        let b = doc([fav("ssh:w:/a", path: "/old", at: t1)])
        let local = doc([fav("ssh:w:/a", path: "/old", at: .distantPast)])    // unchanged
        let incoming = doc([fav("ssh:w:/a", path: "/REMOTE", at: t2)])        // newer edit elsewhere
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].path == "/REMOTE")
    }

    @Test func localDeleteTombstonesAndBeatsStaleIncoming() {
        let b = doc([fav("ssh:w:/a", at: t1)])
        let local = doc()                                   // removed locally
        let incoming = doc([fav("ssh:w:/a", at: t1)])       // peer still has the old copy
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites.count == 1)
        #expect(out.remoteFavorites[0].deleted == true)     // tombstone retained
        #expect(out.remoteFavorites[0].updatedAt == now)
    }

    @Test func tombstoneBeatsStaleReadd() {
        let b = doc([fav("ssh:w:/a", at: t2, deleted: true)])   // already a tombstone
        let local = doc()                                        // still absent locally
        let incoming = doc([fav("ssh:w:/a", at: t1)])            // stale re-add (older)
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].deleted == true)          // stays deleted
    }

    @Test func freshReaddBeatsTombstone() {
        let b = doc([fav("ssh:w:/a", at: t1, deleted: true)])
        let local = doc()
        let incoming = doc([fav("ssh:w:/a", at: t2)])            // re-added later
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].deleted == false)
    }

    @Test func concurrentIndependentItemsBothSurvive() {
        let out = SyncMerge.reconcile(
            baseline: doc(),
            local: doc([fav("ssh:w:/a", at: .distantPast)]),
            incoming: doc([fav("ssh:w:/b", at: t2)]),
            now: now)
        #expect(Set(out.remoteFavorites.map(\.ref)) == ["ssh:w:/a", "ssh:w:/b"])
    }

    @Test func oldTombstonesArePruned() {
        let ancient = Date(timeIntervalSince1970: 0)            // ~Jan 1970, far past horizon
        let b = doc([fav("ssh:w:/a", at: ancient, deleted: true)])
        let out = SyncMerge.reconcile(baseline: b, local: doc(), incoming: doc(), now: now)
        #expect(out.remoteFavorites.isEmpty)                    // pruned
    }

    @Test func emptyIncomingPreservesLocal() {
        let b = doc([fav("ssh:w:/a", at: t1)])
        let local = doc([fav("ssh:w:/a", at: .distantPast)])    // unchanged
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: doc(), now: now)
        #expect(out.remoteFavorites.map(\.ref) == ["ssh:w:/a"])
    }

    @Test func manualHostsReconcileByAlias() {
        let h = ManualHostRecord(alias: "web1", hostname: "10.0.0.5", user: "deploy",
                                 port: 22, identityFile: nil, updatedAt: .distantPast, deleted: false)
        let out = SyncMerge.reconcile(baseline: doc(), local: doc([], [h]),
                                      incoming: doc(), now: now)
        #expect(out.manualHosts.map(\.alias) == ["web1"])
        #expect(out.manualHosts[0].updatedAt == now)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'SyncDocument' / 'SyncMerge' / 'RemoteFavoriteRecord' in scope`.

- [ ] **Step 3: Create `Sources/LumeKit/Sync/SyncDocument.swift`**

```swift
import Foundation

/// The JSON sync document — the wire format mirrored across a user's Macs via
/// iCloud. Pure data; `SyncMerge` reconciles two of these. Timestamps/tombstones
/// live ONLY here and in the engine, never in the SwiftData models.
public struct SyncDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var remoteFavorites: [RemoteFavoriteRecord]
    public var manualHosts: [ManualHostRecord]

    public init(schemaVersion: Int = 1,
                remoteFavorites: [RemoteFavoriteRecord] = [],
                manualHosts: [ManualHostRecord] = []) {
        self.schemaVersion = schemaVersion
        self.remoteFavorites = remoteFavorites
        self.manualHosts = manualHosts
    }
}

/// One synced remote favorite. `ref` is the identity; `updatedAt`/`deleted` are
/// the LWW + tombstone metadata.
public struct RemoteFavoriteRecord: Codable, Equatable, Sendable, SyncRecord {
    public var ref: String
    public var sourceKind: String
    public var sourceKey: String
    public var path: String
    public var isDirectory: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(ref: String, sourceKind: String, sourceKey: String, path: String,
                isDirectory: Bool, updatedAt: Date, deleted: Bool) {
        self.ref = ref; self.sourceKind = sourceKind; self.sourceKey = sourceKey
        self.path = path; self.isDirectory = isDirectory
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    public var identity: String { ref }
    public func sameFields(as other: RemoteFavoriteRecord) -> Bool {
        sourceKind == other.sourceKind && sourceKey == other.sourceKey
            && path == other.path && isDirectory == other.isDirectory
    }
    public func tombstoned(at date: Date) -> RemoteFavoriteRecord {
        var c = self; c.deleted = true; c.updatedAt = date; return c
    }
    public func stamped(at date: Date) -> RemoteFavoriteRecord {
        var c = self; c.updatedAt = date; return c
    }
}

/// One synced manual SSH connection. `alias` is the identity. `identityFile` is
/// a PATH string only — the private key is never synced.
public struct ManualHostRecord: Codable, Equatable, Sendable, SyncRecord {
    public var alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var updatedAt: Date
    public var deleted: Bool

    public init(alias: String, hostname: String?, user: String?, port: Int?,
                identityFile: String?, updatedAt: Date, deleted: Bool) {
        self.alias = alias; self.hostname = hostname; self.user = user
        self.port = port; self.identityFile = identityFile
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    public var identity: String { alias }
    public func sameFields(as other: ManualHostRecord) -> Bool {
        hostname == other.hostname && user == other.user
            && port == other.port && identityFile == other.identityFile
    }
    public func tombstoned(at date: Date) -> ManualHostRecord {
        var c = self; c.deleted = true; c.updatedAt = date; return c
    }
    public func stamped(at date: Date) -> ManualHostRecord {
        var c = self; c.updatedAt = date; return c
    }
}

/// Shared shape that lets `SyncMerge` reconcile both record kinds generically.
public protocol SyncRecord: Equatable {
    var identity: String { get }
    var updatedAt: Date { get }
    var deleted: Bool { get }
    func sameFields(as other: Self) -> Bool
    func tombstoned(at date: Date) -> Self
    func stamped(at date: Date) -> Self
}
```

- [ ] **Step 4: Create `Sources/LumeKit/Sync/SyncMerge.swift`**

```swift
import Foundation

/// The three-way merge at the heart of favorites sync. Pure and time-injected
/// (`now`), so it is fully unit-testable without iCloud.
public enum SyncMerge {
    /// Tombstones older than this are pruned to bound document growth.
    static let tombstoneHorizon: TimeInterval = 30 * 24 * 3600

    /// Reconcile this Mac's `local` projection against the last-synced
    /// `baseline` and the `incoming` iCloud document.
    /// - `local` items carry CURRENT fields; their timestamps are ignored —
    ///   the merge derives each item's effective `updatedAt` by diffing local
    ///   against baseline (changed/new → `now`; unchanged → baseline's time;
    ///   vanished → tombstone at `now`).
    public static func reconcile(baseline: SyncDocument, local: SyncDocument,
                                 incoming: SyncDocument, now: Date) -> SyncDocument {
        SyncDocument(
            schemaVersion: 1,
            remoteFavorites: reconcileList(baseline: baseline.remoteFavorites,
                                           local: local.remoteFavorites,
                                           incoming: incoming.remoteFavorites, now: now),
            manualHosts: reconcileList(baseline: baseline.manualHosts,
                                       local: local.manualHosts,
                                       incoming: incoming.manualHosts, now: now)
        )
    }

    static func reconcileList<R: SyncRecord>(baseline: [R], local: [R],
                                             incoming: [R], now: Date) -> [R] {
        let b = Dictionary(uniqueKeysWithValues: baseline.map { ($0.identity, $0) })
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.identity, $0) })
        let inc = Dictionary(uniqueKeysWithValues: incoming.map { ($0.identity, $0) })
        let ids = Set(b.keys).union(l.keys).union(inc.keys)

        var out: [R] = []
        for id in ids {
            // Effective local record + timestamp, derived against the baseline.
            let localEff: R?
            if let cur = l[id] {
                if let base = b[id], !base.deleted, cur.sameFields(as: base) {
                    localEff = cur.stamped(at: base.updatedAt)   // unchanged since baseline
                } else {
                    localEff = cur.stamped(at: now)              // new or edited locally
                }
            } else if let base = b[id], !base.deleted {
                localEff = base.tombstoned(at: now)              // deleted locally
            } else {
                localEff = b[id]                                 // carry an existing tombstone (or nil)
            }

            // Last-writer-wins between local-effective and incoming.
            let winner = [localEff, inc[id]].compactMap { $0 }
                .max { $0.updatedAt < $1.updatedAt }
            guard let winner else { continue }
            // Prune long-dead tombstones.
            if winner.deleted, now.timeIntervalSince(winner.updatedAt) > tombstoneHorizon { continue }
            out.append(winner)
        }
        return out.sorted { $0.identity < $1.identity }   // deterministic order
    }
}
```

- [ ] **Step 5: Run tests** — Expected: PASS (12 tests). Then the full suite — no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/Sync/ Tests/LumeKitTests/SyncMergeTests.swift
git commit -m "feat: SyncDocument wire format + pure SyncMerge three-way merge"
```

---
### Task 2: `SyncDocumentStore` protocol + ubiquity/file implementation + fake

**Files:**
- Create: `Sources/LumeKit/Sync/SyncDocumentStore.swift`
- Create: `Tests/LumeKitTests/FakeSyncDocumentStore.swift` (test support, shared with Task 3)
- Test: `Tests/LumeKitTests/UbiquityDocumentStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/LumeKitTests/UbiquityDocumentStoreTests.swift` (exercises the real coordinated file I/O + JSON via injected temp URLs):

```swift
import Testing
import Foundation
@testable import LumeKit

struct UbiquityDocumentStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString).json")
    }
    private func sampleFav() -> RemoteFavoriteRecord {
        RemoteFavoriteRecord(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w", path: "/a",
                             isDirectory: false, updatedAt: Date(timeIntervalSince1970: 1), deleted: false)
    }

    @Test func sharedDocumentRoundTrips() throws {
        let shared = tempURL(), baseline = tempURL()
        defer { try? FileManager.default.removeItem(at: shared) }
        let store = UbiquityDocumentStore(sharedURL: shared, baselineURL: baseline)
        #expect(store.isAvailable)
        try store.writeShared(SyncDocument(remoteFavorites: [sampleFav()]))
        let back = try store.readShared()
        #expect(back.remoteFavorites.map(\.ref) == ["ssh:w:/a"])
    }

    @Test func missingSharedReadsEmpty() throws {
        let store = UbiquityDocumentStore(sharedURL: tempURL(), baselineURL: tempURL())
        #expect(try store.readShared() == SyncDocument())   // absent file → empty doc
    }

    @Test func corruptSharedReadsEmpty() throws {
        let shared = tempURL(), baseline = tempURL()
        defer { try? FileManager.default.removeItem(at: shared) }
        try Data("not json".utf8).write(to: shared)
        let store = UbiquityDocumentStore(sharedURL: shared, baselineURL: baseline)
        #expect(try store.readShared() == SyncDocument())   // unreadable → empty, never throws
    }

    @Test func baselineRoundTrips() {
        let baseline = tempURL()
        defer { try? FileManager.default.removeItem(at: baseline) }
        let store = UbiquityDocumentStore(sharedURL: tempURL(), baselineURL: baseline)
        #expect(store.readBaseline() == SyncDocument())     // none yet
        store.writeBaseline(SyncDocument(remoteFavorites: [sampleFav()]))
        #expect(store.readBaseline().remoteFavorites.map(\.ref) == ["ssh:w:/a"])
    }

    @Test func nilSharedMeansUnavailableAndNoOp() throws {
        let store = UbiquityDocumentStore(sharedURL: nil, baselineURL: tempURL())
        #expect(store.isAvailable == false)
        try store.writeShared(SyncDocument(remoteFavorites: [sampleFav()]))  // no-op, no throw
        #expect(try store.readShared() == SyncDocument())
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'UbiquityDocumentStore' in scope`.

- [ ] **Step 3: Create `Sources/LumeKit/Sync/SyncDocumentStore.swift`**

```swift
import Foundation
import os

/// Reads/writes the shared sync document and the local baseline. Abstracted so
/// the engine is testable with an in-memory fake and so the iCloud dependency
/// is one swappable, thin implementation.
public protocol SyncDocumentStore: Sendable {
    /// Whether sync can run (iCloud signed in + ubiquity container resolved).
    var isAvailable: Bool { get }
    /// The shared iCloud document; an absent/unreadable file reads as empty.
    func readShared() throws -> SyncDocument
    /// Replace the shared iCloud document (coordinated). No-op when unavailable.
    func writeShared(_ doc: SyncDocument) throws
    /// The last-merged baseline persisted locally; empty if none.
    func readBaseline() -> SyncDocument
    /// Persist the baseline locally.
    func writeBaseline(_ doc: SyncDocument)
}

/// iCloud-backed store. The shared document lives in the ubiquity container's
/// Documents; the baseline lives in Application Support (never synced). URLs are
/// injectable so tests exercise the real coordinated I/O against temp files; a
/// nil `sharedURL` models "iCloud unavailable" (the dev/ad-hoc-signed reality).
public struct UbiquityDocumentStore: SyncDocumentStore {
    private let sharedURL: URL?
    private let baselineURL: URL
    private static let logger = Logger(subsystem: "com.lume.LumeKit", category: "Sync")

    /// Production locator: nil sharedURL when no ubiquity container is available.
    public static func make() -> UbiquityDocumentStore {
        let ubiquity = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?     // nil → the app's primary container
            .appendingPathComponent("Documents/favorites-sync.json")
        let baseline = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume/favorites-sync-baseline.json")
        return UbiquityDocumentStore(sharedURL: ubiquity, baselineURL: baseline)
    }

    public init(sharedURL: URL?, baselineURL: URL) {
        self.sharedURL = sharedURL
        self.baselineURL = baselineURL
    }

    public var isAvailable: Bool { sharedURL != nil }

    public func readShared() throws -> SyncDocument {
        guard let sharedURL else { return SyncDocument() }
        return Self.coordinatedRead(sharedURL)
    }

    public func writeShared(_ doc: SyncDocument) throws {
        guard let sharedURL else { return }    // unavailable → no-op
        try Self.coordinatedWrite(doc, to: sharedURL)
    }

    public func readBaseline() -> SyncDocument {
        (try? Self.decode(Data(contentsOf: baselineURL))) ?? SyncDocument()
    }

    public func writeBaseline(_ doc: SyncDocument) {
        do {
            try FileManager.default.createDirectory(
                at: baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(doc).write(to: baselineURL, options: .atomic)
        } catch {
            Self.logger.error("baseline write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Coordinated file I/O + JSON

    /// A read that can't decode (absent, partial iCloud download, corrupt) yields
    /// an empty document — favorites are never lost to a bad file.
    private static func coordinatedRead(_ url: URL) -> SyncDocument {
        var result = SyncDocument()
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            if let data = try? Data(contentsOf: readURL), let doc = try? decode(data) {
                result = doc
            }
        }
        return result
    }

    private static func coordinatedWrite(_ doc: SyncDocument, to url: URL) throws {
        let data = try encode(doc)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try FileManager.default.createDirectory(
                    at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: writeURL, options: .atomic)
            } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    private static func encode(_ doc: SyncDocument) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(doc)
    }

    private static func decode(_ data: Data) throws -> SyncDocument {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SyncDocument.self, from: data)
    }
}
```

- [ ] **Step 4: Create `Tests/LumeKitTests/FakeSyncDocumentStore.swift`** (shared with Task 3)

```swift
import Foundation
@testable import LumeKit

/// In-memory `SyncDocumentStore` for engine tests: holds the shared doc and
/// baseline as plain values and records writes for assertions.
final class FakeSyncDocumentStore: SyncDocumentStore, @unchecked Sendable {
    var available: Bool
    var shared: SyncDocument
    var baseline = SyncDocument()
    private(set) var sharedWrites = 0

    init(available: Bool = true, shared: SyncDocument = SyncDocument()) {
        self.available = available
        self.shared = shared
    }

    var isAvailable: Bool { available }
    func readShared() throws -> SyncDocument { shared }
    func writeShared(_ doc: SyncDocument) throws { shared = doc; sharedWrites += 1 }
    func readBaseline() -> SyncDocument { baseline }
    func writeBaseline(_ doc: SyncDocument) { baseline = doc }
}
```

- [ ] **Step 5: Run tests** — Expected: PASS (5 tests). Then full suite — no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/Sync/SyncDocumentStore.swift Tests/LumeKitTests/FakeSyncDocumentStore.swift Tests/LumeKitTests/UbiquityDocumentStoreTests.swift
git commit -m "feat: SyncDocumentStore protocol + iCloud/file store + test fake"
```

---

### Task 3: `FavoritesSyncEngine` — project, reconcile, apply, feedback-loop guard

**Files:**
- Create: `Sources/LumeKit/Sync/FavoritesSyncEngine.swift`
- Test: `Tests/LumeKitTests/FavoritesSyncEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

@MainActor
struct FavoritesSyncEngineTests {
    private func makeEngine(store: FakeSyncDocumentStore, now: Date = Date(timeIntervalSince1970: 3_000))
        throws -> (engine: FavoritesSyncEngine, library: LibraryStore, connections: ConnectionStore, container: Any) {
        let (library, container) = try makeLibrary()
        let connections = ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString).json"))
        let engine = FavoritesSyncEngine(library: library, connections: connections,
                                         store: store, now: { now })
        return (engine, library, connections, container)
    }

    @Test func incomingRemoteFavoriteIsAppliedLocally() throws {
        let incoming = SyncDocument(remoteFavorites: [
            RemoteFavoriteRecord(ref: "ssh:web1:/a", sourceKind: "ssh", sourceKey: "web1",
                                 path: "/a", isDirectory: false,
                                 updatedAt: Date(timeIntervalSince1970: 2_000), deleted: false)
        ])
        let store = FakeSyncDocumentStore(shared: incoming)
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        engine.sync()
        #expect(library.isRemoteFavorite(ref: "ssh:web1:/a"))
    }

    @Test func localRemoteFavoriteIsPushedToShared() throws {
        let store = FakeSyncDocumentStore()
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        library.addRemoteFavorite(ref: "github:o/r:/x.md", sourceKind: "github",
                                  sourceKey: "o/r", path: "/x.md", isDirectory: false)
        engine.sync()
        #expect(store.shared.remoteFavorites.map(\.ref) == ["github:o/r:/x.md"])
        #expect(store.shared.remoteFavorites[0].updatedAt == Date(timeIntervalSince1970: 3_000))
    }

    @Test func incomingTombstoneRemovesLocalFavorite() throws {
        let store = FakeSyncDocumentStore()
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        library.addRemoteFavorite(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w",
                                  path: "/a", isDirectory: false)
        engine.sync()                                  // baseline now has it
        // Peer deletes it later:
        store.shared = SyncDocument(remoteFavorites: [
            RemoteFavoriteRecord(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w", path: "/a",
                                 isDirectory: false, updatedAt: Date(timeIntervalSince1970: 4_000), deleted: true)
        ])
        let later = FavoritesSyncEngine(library: library, connections: store2Connections(),
                                        store: store, now: { Date(timeIntervalSince1970: 5_000) })
        later.sync()
        #expect(library.isRemoteFavorite(ref: "ssh:w:/a") == false)
    }
    private func store2Connections() -> ConnectionStore {
        ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString).json"))
    }

    @Test func manualHostIdentityFileIsStoredTildeRelative() throws {
        let store = FakeSyncDocumentStore()
        let (engine, _, connections, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        let home = NSHomeDirectory()
        connections.addManualHost(SSHHost(alias: "h", hostname: "x", user: nil, port: nil,
                                          identityFile: "\(home)/.ssh/id_x"))
        engine.sync()
        #expect(store.shared.manualHosts.first?.identityFile == "~/.ssh/id_x")
    }

    @Test func appliedManualHostExpandsTilde() throws {
        let store = FakeSyncDocumentStore(shared: SyncDocument(manualHosts: [
            ManualHostRecord(alias: "h", hostname: "x", user: nil, port: nil,
                             identityFile: "~/.ssh/id_x",
                             updatedAt: Date(timeIntervalSince1970: 2_000), deleted: false)
        ]))
        let (engine, _, connections, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        engine.sync()
        let applied = connections.state.manualHosts.first
        #expect(applied?.identityFile == "\(NSHomeDirectory())/.ssh/id_x")
    }

    @Test func unavailableStoreSkipsSyncEntirely() throws {
        let store = FakeSyncDocumentStore(available: false)
        let (engine, library, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        library.addRemoteFavorite(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w",
                                  path: "/a", isDirectory: false)
        engine.sync()
        #expect(store.sharedWrites == 0)               // never wrote
    }

    @Test func onAppliedFiresWhenStoresChange() throws {
        let store = FakeSyncDocumentStore(shared: SyncDocument(remoteFavorites: [
            RemoteFavoriteRecord(ref: "ssh:w:/a", sourceKind: "ssh", sourceKey: "w", path: "/a",
                                 isDirectory: false, updatedAt: Date(timeIntervalSince1970: 2_000), deleted: false)
        ]))
        let (engine, _, _, container) = try makeEngine(store: store)
        defer { withExtendedLifetime(container) {} }
        var fired = 0
        engine.onApplied = { fired += 1 }
        engine.sync()
        #expect(fired == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'FavoritesSyncEngine' in scope`.

- [ ] **Step 3: Create `Sources/LumeKit/Sync/FavoritesSyncEngine.swift`**

```swift
import Foundation
import Observation

/// Drives favorites sync: projects local state → reconciles against the shared
/// iCloud document → applies the result back into the stores → pushes the merged
/// document. The pure merge lives in `SyncMerge`; this shell owns the I/O and the
/// store wiring. Lives in LumeKit (holds `LibraryStore`/`ConnectionStore`); the
/// app sets `onApplied` to refresh its projections.
@MainActor
@Observable
public final class FavoritesSyncEngine {
    private let library: LibraryStore
    private let connections: ConnectionStore
    private let store: any SyncDocumentStore
    private let now: () -> Date

    /// Called after an incoming merge mutates the stores, so the app can refresh.
    public var onApplied: (() -> Void)?

    /// True while applying an incoming merge — suppresses the outbound trigger so
    /// an applied change can't re-stamp and ping-pong.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var debounce: Task<Void, Never>?

    public init(library: LibraryStore, connections: ConnectionStore,
                store: any SyncDocumentStore, now: @escaping () -> Date = Date.init) {
        self.library = library
        self.connections = connections
        self.store = store
        self.now = now
    }

    /// Debounced outbound sync, called after a local pin/unpin or host change.
    public func scheduleSync() {
        guard !isApplying, store.isAvailable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// One full reconcile pass. Safe to call directly (launch, metadata change).
    public func sync() {
        guard store.isAvailable else { return }
        let baseline = store.readBaseline()
        let local = projectLocal()
        let incoming = (try? store.readShared()) ?? SyncDocument()
        let merged = SyncMerge.reconcile(baseline: baseline, local: local,
                                         incoming: incoming, now: now())
        apply(merged)
        try? store.writeShared(merged)
        store.writeBaseline(merged)
    }

    // MARK: - Local projection

    private func projectLocal() -> SyncDocument {
        let favs = library.remoteFavorites().map {
            RemoteFavoriteRecord(ref: $0.ref, sourceKind: $0.sourceKindRaw, sourceKey: $0.sourceKey,
                                 path: $0.path, isDirectory: $0.isDirectory,
                                 updatedAt: .distantPast, deleted: false)   // time set by reconcile
        }
        let hosts = connections.state.manualHosts.map {
            ManualHostRecord(alias: $0.alias, hostname: $0.hostname, user: $0.user, port: $0.port,
                             identityFile: Self.tildeRelative($0.identityFile),
                             updatedAt: .distantPast, deleted: false)
        }
        return SyncDocument(remoteFavorites: favs, manualHosts: hosts)
    }

    // MARK: - Apply merged → stores (guarded)

    private func apply(_ merged: SyncDocument) {
        isApplying = true
        defer { isApplying = false }
        var changed = false

        // Remote favorites: upsert desired, remove the rest.
        let desiredFavs = merged.remoteFavorites.filter { !$0.deleted }
        let desiredRefs = Set(desiredFavs.map(\.ref))
        for rec in desiredFavs where !library.isRemoteFavorite(ref: rec.ref) {
            library.addRemoteFavorite(ref: rec.ref, sourceKind: rec.sourceKind, sourceKey: rec.sourceKey,
                                      path: rec.path, isDirectory: rec.isDirectory)
            changed = true
        }
        for existing in library.remoteFavorites() where !desiredRefs.contains(existing.ref) {
            library.removeRemoteFavorite(ref: existing.ref)
            changed = true
        }

        // Manual hosts: upsert desired (tilde expanded for this Mac), remove the rest.
        let desiredHosts = merged.manualHosts.filter { !$0.deleted }
        let desiredAliases = Set(desiredHosts.map(\.alias))
        let currentByAlias = Dictionary(uniqueKeysWithValues: connections.state.manualHosts.map { ($0.alias, $0) })
        for rec in desiredHosts {
            let host = SSHHost(alias: rec.alias, hostname: rec.hostname, user: rec.user,
                               port: rec.port, identityFile: Self.tildeExpanded(rec.identityFile))
            if currentByAlias[rec.alias] != host {
                connections.addManualHost(host)   // upsert (replaces same alias)
                changed = true
            }
        }
        for existing in connections.state.manualHosts where !desiredAliases.contains(existing.alias) {
            connections.removeManualHost(alias: existing.alias)
            changed = true
        }

        if changed { onApplied?() }
    }

    // MARK: - identityFile portability

    /// `/Users/manu/.ssh/id` → `~/.ssh/id` when under the home dir (so the path
    /// resolves on another Mac with a different username). Other paths unchanged.
    static func tildeRelative(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Inverse: expands a leading `~` to THIS Mac's home dir.
    static func tildeExpanded(_ path: String?) -> String? {
        guard let path else { return nil }
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSString(string: path).expandingTildeInPath
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (7 tests). Then full suite — no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Sync/FavoritesSyncEngine.swift Tests/LumeKitTests/FavoritesSyncEngineTests.swift
git commit -m "feat: FavoritesSyncEngine — project/reconcile/apply with feedback-loop guard"
```

---
### Task 4: iCloud observation + AppState ownership + mutation hooks

**Files:**
- Modify: `Sources/LumeKit/Sync/FavoritesSyncEngine.swift` (NSMetadataQuery observation)
- Modify: `Sources/Lume/AppState.swift` (own the engine; trigger on mutations)

No app-target test bundle; gate is a clean build + the full LumeKit suite green. `NSMetadataQuery` is a system API exercised only by the two-Mac manual checklist (Task 5).

- [ ] **Step 1: Add metadata-query observation to the engine**

In `Sources/LumeKit/Sync/FavoritesSyncEngine.swift`, add a stored query + start/stop methods. Insert after the `debounce` property:

```swift
    @ObservationIgnored private var metadataQuery: NSMetadataQuery?
    @ObservationIgnored private var queryObserver: NSObjectProtocol?
```

Add these methods after `sync()`:

```swift
    /// Begin watching the ubiquity container for changes pushed from another Mac,
    /// and run an initial sync. No-op when iCloud is unavailable.
    public func start() {
        guard store.isAvailable else { return }
        sync()   // pull anything already waiting

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@",
                                      NSMetadataItemFSNameKey, "favorites-sync.json")
        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        metadataQuery = query
        query.start()
    }

    public func stop() {
        metadataQuery?.stop()
        metadataQuery = nil
        if let queryObserver { NotificationCenter.default.removeObserver(queryObserver) }
        queryObserver = nil
        debounce?.cancel()
    }
```

(`NSMetadataQuery` posts its updates on the main run loop; the engine is
`@MainActor`, so `assumeIsolated` is correct here.)

- [ ] **Step 2: Own the engine in `AppState` and start it on attach**

In `AppState.swift`, add a stored property near `let connections = ConnectionStore()` (line ~88):

```swift
    /// Cross-machine favorites sync (iCloud); nil until the library attaches.
    private(set) var favoritesSync: FavoritesSyncEngine?
```

In `attach(library:)` (line ~263), after `refreshLibrary()`, create and start the engine:

```swift
    func attach(library: LibraryStore) {
        self.library = library
        library.migrateBookmarksToFavorites()
        refreshLibrary()
        let engine = FavoritesSyncEngine(
            library: library, connections: connections, store: UbiquityDocumentStore.make())
        engine.onApplied = { [weak self] in self?.refreshLibrary() }
        favoritesSync = engine
        engine.start()
    }
```

- [ ] **Step 3: Trigger a sync after the synced mutations**

The synced mutations are remote-favorite pin/unpin and manual-host add/remove.

In `toggleRemoteFavorite(_:)` and `removeRemoteFavorite(_:)` (the favorites-pinning section), add `favoritesSync?.scheduleSync()` immediately after their `refreshLibrary()` call. For example, `toggleRemoteFavorite` ends:

```swift
        refreshLibrary()
        favoritesSync?.scheduleSync()
    }
```

and `removeRemoteFavorite(_:)`:

```swift
        library?.removeRemoteFavorite(ref: fav.ref)
        refreshLibrary()
        favoritesSync?.scheduleSync()
    }
```

For manual hosts: `connectSSH`'s caller `NewConnectionSheet` adds via
`app.connections.addManualHost(host)`, and removal is `connections.removeManualHost`.
Add a one-line trigger at those call sites. In `Sources/Lume/Remote/NewConnectionSheet.swift`, after `app.connections.addManualHost(host)`:

```swift
        app.connections.addManualHost(host)
        app.favoritesSync?.scheduleSync()
```

(If a manual-host *removal* UI exists, add the same line there. Grep
`removeManualHost` in `Sources/Lume` and add `app.favoritesSync?.scheduleSync()`
after each call. If there are none, note it — removal still syncs on the next
launch/metadata tick via the local-vs-baseline diff.)

- [ ] **Step 4: Stop the engine cleanly (optional lifecycle)**

No explicit teardown is required for a single-window app — the engine lives as
long as `AppState`. Leave `stop()` available for tests/future multi-window use;
do not wire it to a lifecycle event in this task.

- [ ] **Step 5: Build + full suite**

Run: `xcodegen generate && xcodebuild test ... 2>&1 | tail -20`
Expected: BUILD + TEST SUCCEEDED. (Under ad-hoc signing `UbiquityDocumentStore.make()` resolves no ubiquity container → `isAvailable == false` → `start()`/`scheduleSync()` are no-ops; nothing changes behaviorally in dev.)

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/Sync/FavoritesSyncEngine.swift Sources/Lume/AppState.swift Sources/Lume/Remote/NewConnectionSheet.swift
git commit -m "feat: iCloud metadata-query observation + AppState sync ownership and triggers"
```

---

### Task 5: iCloud entitlement + project wiring + manual checklist + README

**Files:**
- Create: `Lume.entitlements`
- Modify: `project.yml` (attach the entitlements to the app target)
- Create: `docs/favorites-sync-manual-test-checklist.md`
- Modify: `README.md`

- [ ] **Step 1: Create `Lume.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.lume.Lume</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudDocuments</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.lume.Lume</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Attach entitlements in `project.yml`**

Find the `Lume` app target's `settings` block (the one with the `CODE_SIGN_IDENTITY: "-"` lines for the app, not the test target). Add under its base settings:

```yaml
        CODE_SIGN_ENTITLEMENTS: Lume.entitlements
```

- [ ] **Step 3: Regenerate + verify the build still succeeds ad-hoc-signed**

Run: `xcodegen generate && xcodebuild build -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -8`
Expected: **BUILD SUCCEEDED**. Ad-hoc signing applies the entitlements best-effort; iCloud APIs stay inert at runtime (no provisioning profile), which is the designed no-op path.

> If the build instead FAILS with a provisioning/entitlement error under ad-hoc signing, back out the `CODE_SIGN_ENTITLEMENTS` line from `project.yml` (keep the `Lume.entitlements` file committed for documentation), regenerate, and record in the commit message that the entitlement must be attached via Xcode's Signing & Capabilities once a real Developer Team is configured. Do not leave the project in a non-building state.

- [ ] **Step 4: Create `docs/favorites-sync-manual-test-checklist.md`**

```markdown
# Favorites Sync — Manual Test Checklist (two Macs)

Prereqs: two Macs signed into the same Apple ID with iCloud Drive on, both
running a Lume build signed with a Developer Team that has the
`iCloud.com.lume.Lume` container enabled (the repo's ad-hoc dev build will
NOT sync — `isAvailable` is false there).

## Favorites
1. [ ] On Mac A, pin an SSH remote file. Within a minute it appears in Mac B's
       Favorites (badge + filename).
2. [ ] On Mac A, pin a GitHub file → appears on Mac B.
3. [ ] On Mac A, unpin one → it disappears on Mac B (tombstone propagates).

## Manual connections
4. [ ] On Mac A, add a New SSH Connection (manual host). On Mac B the host
       appears in the source switcher's Saved Connections, and connecting works
       (assuming the key/agent is set up on B).
5. [ ] Confirm the private key file itself was NOT copied — only the path.
       A host whose `~/.ssh` key is absent on B fails auth (expected).

## Conflict / offline
6. [ ] Turn off Wi-Fi on both. Pin different favorites on each. Reconnect →
       both favorites end up on both Macs (concurrent adds both survive).
7. [ ] Offline, unpin the same favorite on A and edit nothing on B. Reconnect →
       it's gone on both (delete wins / propagates).

## Availability
8. [ ] Sign out of iCloud on Mac B → Lume still works; favorites just stop
       syncing (no errors, no dead-ends). Sign back in → sync resumes.
```

- [ ] **Step 5: Add a README note**

Append to the favorites section of `README.md` (after the "One Favorites list for every source" blurb):

```markdown
### Favorites follow you across Macs

Your remote favorites (SSH + GitHub) and manually-added SSH connections sync
across the Macs signed into your iCloud account — pin a remote file on one,
find it on the other; remove it anywhere, it's gone everywhere. Local-file
favorites and your private keys stay on each machine. Requires iCloud Drive
and a signed build with the iCloud capability; without iCloud, favorites work
normally and just don't sync.
```

- [ ] **Step 6: Final full suite**

Run: `xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -20`
Expected: TEST SUCCEEDED — all suites.

- [ ] **Step 7: Commit**

```bash
git add Lume.entitlements project.yml docs/favorites-sync-manual-test-checklist.md README.md
git commit -m "feat: iCloud entitlement + favorites-sync manual checklist + README"
```


