# Token-Budget Surfacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Surface per-file token weight where files are listed (Scan triage + BundleView), with a sort-by-size toggle and an over-budget tint, reusing Phase 1's `chars/4` heuristic via a new `TokenEstimator`.

**Architecture:** New pure `TokenEstimator` in LumeKit (badges use a fast `bytes/4` per-file estimate; `ContextAssembler` refactored to reuse `estimate(text)`). Two SwiftUI views gain off-main-loaded badge caches. No new screens, no model changes.

**Tech Stack:** Swift, SwiftUI + AppKit, Swift Testing, XcodeGen project.

---

## Conventions
**Test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -only-testing:LumeKitTests 2>&1 | tail -25`
**Build:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -quiet 2>&1 | tail -25`
New `.swift` files → run `xcodegen generate` before building. Native Write/Edit only. Branch: `feat/token-budget`.

---

## Task 1: TokenEstimator + refactor ContextAssembler (TDD)

**Files:**
- Create: `Sources/LumeKit/Document/TokenEstimator.swift`
- Modify: `Sources/LumeKit/Document/ContextAssembler.swift`
- Test: `Tests/LumeKitTests/TokenEstimatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LumeKitTests/TokenEstimatorTests.swift
import Testing
import Foundation
@testable import LumeKit

private func tokTempFile(_ name: String, bytes: Int) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tok-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try String(repeating: "x", count: bytes).write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func estimateIsCharsOverFour() {
    #expect(TokenEstimator.estimate("") == 0)
    #expect(TokenEstimator.estimate("abcd") == 1)
    #expect(TokenEstimator.estimate("abcde") == 2)
}

@Test func estimateFileFromByteSize() throws {
    let url = try tokTempFile("a.txt", bytes: 40)
    #expect(TokenEstimator.estimateFile(url) == 10)
    #expect(TokenEstimator.estimateFile(URL(fileURLWithPath: "/nope/\(UUID().uuidString).txt")) == nil)
}

@Test func formatCompacts() {
    #expect(TokenEstimator.format(nil) == "—")
    #expect(TokenEstimator.format(512) == "~512")
    #expect(TokenEstimator.format(1200) == "~1.2k")
    #expect(TokenEstimator.format(45000) == "~45k")
}
```

- [ ] **Step 2: Run tests, confirm fail** (TokenEstimator undefined). Run the Test command.

- [ ] **Step 3: Create TokenEstimator**

```swift
// Sources/LumeKit/Document/TokenEstimator.swift
import Foundation

/// Rough token estimates using the chars≈tokens÷4 heuristic shared with ContextAssembler.
public enum TokenEstimator {
    /// Token estimate for in-memory text: chars ÷ 4.
    public static func estimate(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 4.0))
    }

    /// Fast per-file estimate from on-disk byte size ÷ 4 (no file read). nil if unavailable.
    public static func estimateFile(_ url: URL) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return nil }
        return Int(ceil(Double(size) / 4.0))
    }

    /// Compact label: "~512", "~1.2k", "~45k"; nil → "—".
    public static func format(_ tokens: Int?) -> String {
        guard let t = tokens else { return "—" }
        if t < 1000 { return "~\(t)" }
        let k = Double(t) / 1000.0
        return k < 10 ? "~\(String(format: "%.1f", k))k" : "~\(Int(k))k"
    }
}
```

- [ ] **Step 4: Refactor ContextAssembler to reuse `estimate`**

In `Sources/LumeKit/Document/ContextAssembler.swift`, find:
```swift
        let estimate = Int(ceil(Double(text.count) / 4.0))
```
Replace with:
```swift
        let estimate = TokenEstimator.estimate(text)
```

- [ ] **Step 5: Run tests, confirm all pass** (new TokenEstimator tests + existing ContextAssembler token test unchanged). Run the Test command.

- [ ] **Step 6: Commit**
```bash
xcodegen generate
git add Sources/LumeKit/Document/TokenEstimator.swift Sources/LumeKit/Document/ContextAssembler.swift Tests/LumeKitTests/TokenEstimatorTests.swift
git commit -m "feat: add TokenEstimator and reuse it in ContextAssembler"
```

---

## Task 2: Scan triage — token badges + sort-by-size

**Files:**
- Modify: `Sources/Lume/Scans/ScanTriageView.swift`

- [ ] **Step 1: Add state + displayed-results + size loader**

Add these `@State` properties near the existing ones (after line 10 `@State private var preview = ""`):
```swift
    @State private var sizes: [String: Int] = [:]
    @State private var sortBySize = false
```

Add a computed property and a loader (e.g. after `parentLabel`):
```swift
    /// Scan results in display order: by token size (desc) when the toggle is on.
    private var displayedResults: [URL] {
        guard sortBySize else { return app.scanResults }
        return app.scanResults.sorted { (sizes[$0.path] ?? 0) > (sizes[$1.path] ?? 0) }
    }

    private func loadSizes(_ urls: [URL]) async {
        let paths = urls.map(\.path)
        let computed = await Task.detached(priority: .utility) { () -> [String: Int] in
            var out: [String: Int] = [:]
            for p in paths {
                if let t = TokenEstimator.estimateFile(URL(fileURLWithPath: p)) { out[p] = t }
            }
            return out
        }.value
        sizes = computed
    }
```

- [ ] **Step 2: Load sizes when results change**

In `body`, add a second `.task` after the existing `.task(id: app.scanFocusURL)` line (line 22):
```swift
        .task(id: app.scanResults) { await loadSizes(app.scanResults) }
```

- [ ] **Step 3: Iterate displayed results + add the badge**

In `fileList`, change `ForEach(app.scanResults, id: \.self) { url in` to:
```swift
            ForEach(displayedResults, id: \.self) { url in
```
And inside the row `HStack`, add a trailing badge before the closing of the HStack (after the `VStack { … }` that holds the name/parent, line 52):
```swift
                    Spacer()
                    Text(TokenEstimator.format(sizes[url.path]))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
```

- [ ] **Step 4: Add the sort toggle to the header**

In `header`, before the `Rescan` button (line 31), add:
```swift
            Button { sortBySize.toggle() } label: {
                Label("Sort by size", systemImage: "arrow.up.arrow.down")
            }
            .help(sortBySize ? "Sorting by token size" : "Sort by token size")
            .tint(sortBySize ? .accentColor : nil)
```

- [ ] **Step 5: Build, confirm success.** Run the Build command.

- [ ] **Step 6: Commit**
```bash
git add Sources/Lume/Scans/ScanTriageView.swift
git commit -m "feat: per-file token badges and sort-by-size in Scan triage"
```

---

## Task 3: BundleView — per-file badges + over-budget tint

**Files:**
- Modify: `Sources/Lume/Bundles/BundleView.swift`

- [ ] **Step 1: Add size cache + threshold + loader**

Add near the existing `@State` (after line 10 `@State private var tokenEstimate = 0`):
```swift
    @State private var sizes: [String: Int] = [:]

    private let budgetWarnThreshold = 100_000
```

Add a loader (after `recomputeEstimate()`):
```swift
    private func loadSizes(_ paths: [String]) async {
        let computed = await Task.detached(priority: .utility) { () -> [String: Int] in
            var out: [String: Int] = [:]
            for p in paths {
                if let t = TokenEstimator.estimateFile(URL(fileURLWithPath: p)) { out[p] = t }
            }
            return out
        }.value
        sizes = computed
    }
```

- [ ] **Step 2: Load sizes when paths change**

In `body`, add after the `.task(id: estimateKey)` line (line 31):
```swift
        .task(id: bundle?.paths) { await loadSizes(bundle?.paths ?? []) }
```

- [ ] **Step 3: Add the per-row badge**

In `fileList`, inside the row `HStack`, between the `Spacer()` (line 68) and the remove `Button` (line 69), add (only show a value for existing files):
```swift
                    if exists {
                        Text(TokenEstimator.format(sizes[path]))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
```

- [ ] **Step 4: Over-budget tint on the total**

In `actionBar`, change:
```swift
            Text("~\(tokenEstimate) tokens · \(existingURLs.count) files")
                .foregroundStyle(.secondary)
```
to:
```swift
            Text("~\(tokenEstimate) tokens · \(existingURLs.count) files")
                .foregroundStyle(tokenEstimate > budgetWarnThreshold ? Color.orange : Color.secondary)
```

- [ ] **Step 5: Build, confirm success.** Run the Build command.

- [ ] **Step 6: Commit**
```bash
git add Sources/Lume/Bundles/BundleView.swift
git commit -m "feat: per-file token badges and over-budget tint in BundleView"
```

---

## Task 4: Verify

- [ ] **Step 1: Full suite.** Run the Test command. Expected: all pass (Phase 1's 137 + 3 new TokenEstimator tests = 140).
- [ ] **Step 2: Build.** Run the Build command. Expected: success.
- [ ] **Step 3: Manual smoke:** run a Scan → rows show `~N`/`~N.Nk` badges; toggle sort-by-size → biggest file tops the list. Open a bundle → rows show badges; a large bundle tints the total orange.

---

## Self-Review Notes
- Spec coverage: TokenEstimator (T1), ContextAssembler reuse (T1), scan badges + sort (T2), bundle badges + tint (T3). All mapped.
- Type consistency: `TokenEstimator.estimate/estimateFile/format`, `sizes: [String: Int]`, `displayedResults`, `loadSizes` used consistently.
- Off-main: both `loadSizes` use `Task.detached`; no main-thread file I/O added.
