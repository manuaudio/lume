# Activity Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Capture the changed file paths the FSEvents watcher already delivers into an in-memory log, and show a glanceable sidebar "Activity" region of recent changes with click-to-open and Clear.

**Architecture:** Pure `ActivityLog` value type in LumeKit (dedupe/cap/ignore-filter, tested). `AppState` records into it from the existing watcher handler. A new `ActivityRegion` in the sidebar renders it. No detail-pane or routing changes.

**Tech Stack:** Swift, SwiftUI + AppKit, Swift Testing, XcodeGen project.

---

## Conventions
**Test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -only-testing:LumeKitTests 2>&1 | tail -25`
**Build:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -quiet 2>&1 | tail -25`
New `.swift` files → `xcodegen generate` before build/test. Native Write/Edit only. Branch: `feat/activity-feed`.

---

## Task 1: ActivityLog (TDD)

**Files:**
- Create: `Sources/LumeKit/Document/ActivityLog.swift`
- Test: `Tests/LumeKitTests/ActivityLogTests.swift`

- [ ] **Step 1: Failing tests**

```swift
// Tests/LumeKitTests/ActivityLogTests.swift
import Testing
import Foundation
@testable import LumeKit

@Test func recordsNewestFirstAndDedupes() {
    var log = ActivityLog(limit: 10)
    let t0 = Date(timeIntervalSince1970: 0)
    log.record("/a", at: t0)
    log.record("/b", at: t0.addingTimeInterval(1))
    #expect(log.entries.map(\.path) == ["/b", "/a"])
    log.record("/a", at: t0.addingTimeInterval(2))   // re-touch moves to front
    #expect(log.entries.map(\.path) == ["/a", "/b"])
    #expect(log.entries.count == 2)
}

@Test func capsToLimit() {
    var log = ActivityLog(limit: 2)
    let t = Date(timeIntervalSince1970: 0)
    log.record("/a", at: t)
    log.record("/b", at: t)
    log.record("/c", at: t)
    #expect(log.entries.map(\.path) == ["/c", "/b"])
}

@Test func clearEmpties() {
    var log = ActivityLog()
    log.record("/a", at: Date(timeIntervalSince1970: 0))
    log.clear()
    #expect(log.entries.isEmpty)
}

@Test func ignoresVendorDirs() {
    #expect(ActivityLog.isIgnored("/proj/node_modules/x.js"))
    #expect(ActivityLog.isIgnored("/proj/.git/HEAD"))
    #expect(!ActivityLog.isIgnored("/proj/CLAUDE.md"))
    #expect(!ActivityLog.isIgnored("/proj/.env"))
}
```

- [ ] **Step 2: Run tests, confirm fail** (after `xcodegen generate`). Run the Test command.

- [ ] **Step 3: Implement**

```swift
// Sources/LumeKit/Document/ActivityLog.swift
import Foundation

/// One recently-changed file.
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let date: Date
    public var id: String { path }
    public init(path: String, date: Date) { self.path = path; self.date = date }
}

/// A capped, deduped, newest-first log of recently-changed files (session-scoped).
public struct ActivityLog: Equatable, Sendable {
    public private(set) var entries: [ActivityEntry] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    /// Upsert a path to the front with `date`; removes any prior entry for it; caps to `limit`.
    public mutating func record(_ path: String, at date: Date) {
        entries.removeAll { $0.path == path }
        entries.insert(ActivityEntry(path: path, date: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func record(_ paths: [String], at date: Date) {
        for path in paths { record(path, at: date) }
    }

    public mutating func clear() { entries.removeAll() }

    /// True if any path component is a vendored/ignored directory.
    public static func isIgnored(_ path: String) -> Bool {
        let components = Set((path as NSString).pathComponents)
        return !components.isDisjoint(with: ScanEngine.ignoredDirectories)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass.** Run the Test command.

- [ ] **Step 5: Commit**
```bash
xcodegen generate
git add Sources/LumeKit/Document/ActivityLog.swift Tests/LumeKitTests/ActivityLogTests.swift
git commit -m "feat: add ActivityLog (capped, deduped recent-changes log)"
```

---

## Task 2: AppState — record watcher changes

**Files:**
- Modify: `Sources/Lume/AppState.swift`

(No unit test — app glue; ActivityLog logic is tested in Task 1. Verify by build.)

- [ ] **Step 1: Add the log state + accessor + clear.** Near the other state, add:
```swift
    // MARK: - Activity feed
    private(set) var activity = ActivityLog()
    var recentChanges: [ActivityEntry] { activity.entries }
    func clearActivityLog() { activity.clear() }
```

- [ ] **Step 2: Record changes in the watcher handler.** In `startWatching(_:)`, the current handler is:
```swift
        watcher = DirectoryWatcher(root: root) { [weak self] changed in
            guard let self else { return }
            for path in changed { self.cache.invalidate(path: path) }
            self.refreshLibrary()
        }
```
Change it to also record recordable changes (assigning a local copy back once for a single observation notification):
```swift
        watcher = DirectoryWatcher(root: root) { [weak self] changed in
            guard let self else { return }
            for path in changed { self.cache.invalidate(path: path) }
            let recordable = changed.filter { !ActivityLog.isIgnored($0) && self.isRegularFile($0) }
            if !recordable.isEmpty {
                var log = self.activity
                log.record(recordable, at: Date())
                self.activity = log
            }
            self.refreshLibrary()
        }
```

- [ ] **Step 3: Add the file-check helper.** Near the other private file helpers (e.g. by `fm`), add:
```swift
    /// True if `path` is an existing regular file (not a directory).
    private func isRegularFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
```
(Confirm `fm` is the `FileManager` property already on AppState; it is used elsewhere in the file.)

- [ ] **Step 4: Build, confirm success.** Run the Build command.

- [ ] **Step 5: Commit**
```bash
git add Sources/Lume/AppState.swift
git commit -m "feat: record watcher file changes into the activity log"
```

---

## Task 3: Sidebar Activity region

**Files:**
- Modify: `Sources/Lume/SidebarView.swift`

- [ ] **Step 1: Add the region to the list.** In `SidebarView.body`, after `BundlesRegion()`, add:
```swift
                    ActivityRegion()
```

- [ ] **Step 2: Define the region.** Add this `private struct` near the other regions (e.g. after `BundlesRegion`):
```swift
private struct ActivityRegion: View {
    @Environment(AppState.self) private var app

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Section {
            if app.recentChanges.isEmpty {
                Text("Edits under this folder show up here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.recentChanges.prefix(8)) { entry in
                    let url = URL(fileURLWithPath: entry.path)
                    Button {
                        app.choose(url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent).font(.body).lineLimit(1)
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Self.timeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack(spacing: 10) {
                Text("Activity")
                Spacer()
                if !app.recentChanges.isEmpty {
                    Button { app.clearActivityLog() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Clear activity")
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build, confirm success.** Run the Build command.

- [ ] **Step 4: Commit**
```bash
git add Sources/Lume/SidebarView.swift
git commit -m "feat: sidebar Activity region for recent file changes"
```

---

## Task 4: Verify

- [ ] **Step 1: Full suite.** Run the Test command. Expected: all pass (146 + 4 new ActivityLog tests = 150).
- [ ] **Step 2: Build.** Run the Build command. Expected: success.
- [ ] **Step 3: Manual smoke:** open a folder; in Terminal `echo x >> <that folder>/somefile.md`; within ~0.5s the Activity region lists `somefile.md` with "now"/"Xs ago"; click it → opens in the detail pane; edits under `node_modules` do NOT appear; Clear empties the region.

---

## Self-Review Notes
- Spec coverage: ActivityLog dedupe/cap/ignore (T1), record from watcher + filter regular-file/ignored (T2), sidebar region + click-open + clear (T3). All mapped.
- Type consistency: `ActivityEntry`/`ActivityLog.record/clear/isIgnored`, `AppState.activity/recentChanges/clearActivityLog`, `isRegularFile`, `app.choose` used consistently.
- Off-main: recording happens in the watcher's main-actor `onChange` (already hopped to main); only cheap `fileExists` stats per burst, coalesced by the watcher's 0.25s latency.
