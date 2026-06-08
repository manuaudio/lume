# Activity Feed — Design Spec

**Date:** 2026-06-08
**Status:** Approved for planning
**Phase:** 4 of 4 (final) in the "Context Cockpit" roadmap.

## Problem

The FSEvents `DirectoryWatcher` already fires on every change under the open folder and **already carries the changed file paths** — but `AppState` discards them and only invalidates its cache. So when an agent rewrites `CLAUDE.md`, `memory.md`, or `.env` files, you get no visibility into what just changed. Phase 4 surfaces that stream: a glanceable feed of recently-changed files.

## Goals

1. Capture changed file paths from the existing watcher into an in-memory, capped, deduped, newest-first log.
2. Show a sidebar **Activity** region: recent changes with relative time, click-to-open.
3. A **Clear** action.

## Non-Goals (v1)

- No multi-root watching — scope is the currently-open folder subtree (what the single watcher already covers). Multi-root is a followup.
- No persistence — the feed is session-scoped ("recent activity").
- No deletion events — a change to a now-missing file is skipped (we only record existing regular files).
- No new detail-pane view or routing — it lives entirely in the sidebar.

## Design

### ActivityLog (LumeKit/Document/ActivityLog.swift) — pure, tested

```swift
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let date: Date
    public var id: String { path }
}

public struct ActivityLog: Equatable, Sendable {
    public private(set) var entries: [ActivityEntry]   // newest first
    public let limit: Int
    public init(limit: Int = 200)
    public mutating func record(_ path: String, at date: Date)   // upsert to front, dedupe by path, cap
    public mutating func record(_ paths: [String], at date: Date)
    public mutating func clear()
    /// True if any path component is a vendored/ignored dir (reuses ScanEngine.ignoredDirectories).
    public static func isIgnored(_ path: String) -> Bool
}
```

### AppState (Sources/Lume/AppState.swift)

- `private(set) var activity = ActivityLog()`.
- `var recentChanges: [ActivityEntry] { activity.entries }`.
- In `startWatching`'s `onChange` handler (which already gets the changed `Set<String>`), additionally: filter to paths that are **existing regular files** and **not** `ActivityLog.isIgnored`, then record them in one batch via a local copy assigned back once (single observation notification):
  ```swift
  let recordable = changed.filter { !ActivityLog.isIgnored($0) && isRegularFile($0) }
  if !recordable.isEmpty { var log = activity; log.record(recordable, at: Date()); activity = log }
  ```
- `func clearActivityLog() { activity.clear() }`.

### SidebarView (Sources/Lume/SidebarView.swift)

A new `ActivityRegion` placed after `BundlesRegion`:
- Header "Activity" with a **Clear** button (shown when non-empty).
- Empty: tertiary text "Edits under this folder show up here."
- Otherwise: the most recent ~8 entries, each a row — file name, parent folder (abbreviated, caption), relative time ("2m ago", `RelativeDateTimeFormatter`) — `Button` that calls `app.choose(url)` to open it.

## Data Flow

```
FSEvents → DirectoryWatcher.onChange(changed paths) → AppState filters (regular file, not ignored)
        → activity.record(batch, Date()) → sidebar ActivityRegion rows → app.choose(url)
```

## Error Handling / Edges

| Case | Behavior |
|------|----------|
| Changed path is a directory | Skipped (only regular files recorded). |
| Changed path now missing (delete) | Skipped (fails existence check). |
| Path under node_modules/.git/.build/etc. | Skipped via `isIgnored`. |
| Same file changes repeatedly | Single entry, moved to front with newest time. |
| App's own save/overwrite fires watcher | Recorded (it did change) — acceptable. |
| Switching open folder | New watcher; log persists for the session (cross-folder history is fine). |

## Testing

`ActivityLogTests` (Swift Testing, explicit dates):
- record newest-first + dedupe (re-touch moves to front, count stable).
- cap to limit (oldest dropped).
- clear empties.
- `isIgnored`: node_modules/.git true; CLAUDE.md/.env false.

Sidebar UI verified by build + manual smoke (touch a file under the open folder → it appears; click opens it; Clear empties).

## Followups

- Multi-root watching (Scan roots + bookmarks), not just the open folder.
- Persist a short history; show change kind (created/modified/deleted).
- Filter the feed by file type or by Scan pattern.
