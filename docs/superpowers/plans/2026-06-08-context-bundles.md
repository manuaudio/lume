# Context Bundles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users turn a set of files (a browser selection or a Scan's ticked set) into one pasteable blob of file *contents* (XML or Markdown, with a token estimate), and save those sets as reusable named Bundles — with a warning before secrets are copied.

**Architecture:** Pure, testable logic lives in `LumeKit` (`ContextAssembler`, `SecretDetector`, `ContextFormat`, `ContextBundle` model, `LibraryStore` CRUD). The `Lume` app layer wires it into `AppState`, a new sidebar **Bundles** region, a `BundleView` detail pane, a secret-confirmation dialog, and menu commands. `ContextBundle` mirrors the existing `Scan` model; `BundlesRegion` mirrors `ScansRegion`; `BundleView` mirrors `ScanTriageView`. `PathExport` is left untouched (it stays the path-only export).

**Tech Stack:** Swift, SwiftUI + AppKit, SwiftData, Swift Testing (`import Testing`), Xcode project (`Lume.xcodeproj`).

---

## Conventions (read once)

**Test command** — runs the whole `LumeKitTests` bundle (reliable with Swift Testing free functions):
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=macOS' -only-testing:LumeKitTests 2>&1 | tail -25
```

**Build command** (compiles `LumeKit` + app; use for UI tasks that have no unit test):
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=macOS' -quiet 2>&1 | tail -25
```

**SwiftData gotcha (already learned):** in-memory `ModelContainer` must be retained for the whole test body — use `defer { withExtendedLifetime(container) {} }`. New non-optional `@Model` properties need a **property-level default** with a fully-qualified value (`Date.now`, not an expression).

**Branch:** all work lands on `feat/context-bundles` (already checked out).

---

## File Structure

**Create (LumeKit — pure logic):**
- `Sources/LumeKit/Document/ContextFormat.swift` — the `.xml` / `.markdown` enum.
- `Sources/LumeKit/Document/ContextAssembler.swift` — reads files, wraps them, estimates tokens.
- `Sources/LumeKit/Document/SecretDetector.swift` — flags `.env`/secret filenames.
- `Sources/LumeKit/Library/ContextBundle.swift` — the `@Model`.

**Create (LumeKit tests):**
- `Tests/LumeKitTests/ContextAssemblerTests.swift`
- `Tests/LumeKitTests/SecretDetectorTests.swift`
- `Tests/LumeKitTests/LibraryStoreBundleTests.swift`

**Create (Lume — UI):**
- `Sources/Lume/Bundles/BundleView.swift` — the detail pane for an open bundle.

**Modify:**
- `Sources/Lume/LumeApp.swift:12` — register `ContextBundle.self` in the schema.
- `Sources/LumeKit/Library/LibraryStore.swift` — add a `// MARK: - Bundles` CRUD section.
- `Sources/Lume/AppState.swift` — context-copy + bundle state/methods + routing clears.
- `Sources/Lume/Scans/ScanTriageView.swift` — add a "Copy as Context" button to the action bar.
- `Sources/Lume/SidebarView.swift` — add a `BundlesRegion`, place it after `ScansRegion`.
- `Sources/Lume/ContentView.swift` — route to `BundleView` when a bundle is active; host the secret dialog.
- `Sources/Lume/LumeCommands.swift` — add a `Context` command menu.

---

## Task 1: ContextFormat enum

**Files:**
- Create: `Sources/LumeKit/Document/ContextFormat.swift`

- [ ] **Step 1: Write the enum** (no separate test — it's a trivial value type exercised by Task 2's tests)

```swift
// Sources/LumeKit/Document/ContextFormat.swift
import Foundation

/// How `ContextAssembler` wraps file contents for an LLM paste.
public enum ContextFormat: String, CaseIterable, Sendable {
    /// `<documents><document path="…">…</document></documents>` — Claude-preferred.
    case xml
    /// `## path` + a language-fenced code block — portable across chatbots.
    case markdown

    /// Short label for menus/pickers.
    public var label: String {
        switch self {
        case .xml: return "XML"
        case .markdown: return "Markdown"
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run the **Build command**.
Expected: build succeeds (no test yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/LumeKit/Document/ContextFormat.swift
git commit -m "feat: add ContextFormat enum (xml/markdown)"
```

---

## Task 2: ContextAssembler

The heart of the feature: read files, wrap them, estimate tokens, collect unreadable files.

**Files:**
- Create: `Sources/LumeKit/Document/ContextAssembler.swift`
- Test: `Tests/LumeKitTests/ContextAssemblerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LumeKitTests/ContextAssemblerTests.swift
import Testing
import Foundation
@testable import LumeKit

/// Write `contents` to a uniquely-named file in a temp dir, return its URL.
private func tempFile(_ name: String, _ contents: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ctxasm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func assembleXMLWrapsEachFile() throws {
    let a = try tempFile("CLAUDE.md", "# Rules\nUse TDD")
    let b = try tempFile("config.json", "{\"k\":1}")
    let result = ContextAssembler.assemble([a, b], format: .xml)

    #expect(result.fileCount == 2)
    #expect(result.unreadable.isEmpty)
    #expect(result.text.hasPrefix("<documents>"))
    #expect(result.text.hasSuffix("</documents>"))
    #expect(result.text.contains("<document path=\"\(ContextAssembler.displayPath(a))\">"))
    #expect(result.text.contains("# Rules\nUse TDD"))
    #expect(result.text.contains("{\"k\":1}"))
}

@Test func assembleMarkdownInfersLanguageAndHeading() throws {
    let py = try tempFile("script.py", "print('hi')")
    let result = ContextAssembler.assemble([py], format: .markdown)

    #expect(result.text.contains("## \(ContextAssembler.displayPath(py))"))
    #expect(result.text.contains("```python"))
    #expect(result.text.contains("print('hi')"))
}

@Test func markdownFenceLongerThanContentBackticks() throws {
    // A markdown file that itself contains a triple-backtick block must be
    // wrapped in a LONGER fence so it doesn't break out.
    let md = try tempFile("CLAUDE.md", "Example:\n```\ncode\n```\n")
    let result = ContextAssembler.assemble([md], format: .markdown)
    #expect(result.text.contains("````markdown"))   // 4 backticks, not 3
}

@Test func tokenEstimateIsCharsOverFour() throws {
    let f = try tempFile("a.txt", "abcdefgh")   // 8 chars of content
    let result = ContextAssembler.assemble([f], format: .xml)
    // estimate is over the FULL wrapped text, not just the body
    #expect(result.tokenEstimate == Int(ceil(Double(result.text.count) / 4.0)))
    #expect(result.tokenEstimate > 0)
}

@Test func unreadableFilesAreCollectedNotDropped() throws {
    let good = try tempFile("good.md", "hello")
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).md")
    let result = ContextAssembler.assemble([good, missing], format: .xml)

    #expect(result.fileCount == 1)
    #expect(result.unreadable == [missing])
    #expect(result.text.contains("hello"))
}

@Test func emptyInputYieldsEmptyResult() {
    let result = ContextAssembler.assemble([], format: .xml)
    #expect(result.text.isEmpty)
    #expect(result.tokenEstimate == 0)
    #expect(result.fileCount == 0)
}

@Test func displayPathAbbreviatesHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let url = home.appendingPathComponent("proj/CLAUDE.md")
    #expect(ContextAssembler.displayPath(url) == "~/proj/CLAUDE.md")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the **Test command**.
Expected: compile failure — `ContextAssembler` is undefined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LumeKit/Document/ContextAssembler.swift
import Foundation

/// The result of bundling files' contents for an LLM paste.
public struct AssembledContext: Equatable {
    public let text: String
    public let tokenEstimate: Int
    public let fileCount: Int
    public let unreadable: [URL]
}

/// Reads files and wraps their contents into one pasteable blob.
/// Pure and `nonisolated` — safe to run off the main actor and unit-test directly.
public enum ContextAssembler {

    public static func assemble(_ urls: [URL], format: ContextFormat) -> AssembledContext {
        var pieces: [(url: URL, body: String)] = []
        var unreadable: [URL] = []
        for url in urls {
            if let body = try? String(contentsOf: url, encoding: .utf8) {
                pieces.append((url, body))
            } else {
                unreadable.append(url)
            }
        }
        guard !pieces.isEmpty else {
            return AssembledContext(text: "", tokenEstimate: 0, fileCount: 0, unreadable: unreadable)
        }

        let text: String
        switch format {
        case .xml:
            let docs = pieces.map { p in
                "<document path=\"\(xmlAttrEscape(displayPath(p.url)))\">\n\(p.body)\n</document>"
            }.joined(separator: "\n")
            text = "<documents>\n\(docs)\n</documents>"
        case .markdown:
            text = pieces.map { p in
                let lang = fenceLanguage(for: p.url)
                let fence = fence(for: p.body)
                return "## \(displayPath(p.url))\n\(fence)\(lang)\n\(p.body)\n\(fence)"
            }.joined(separator: "\n\n")
        }

        let estimate = Int(ceil(Double(text.count) / 4.0))
        return AssembledContext(text: text, tokenEstimate: estimate,
                                fileCount: pieces.count, unreadable: unreadable)
    }

    /// Absolute POSIX path with the home directory shown as `~`.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Markdown code-fence language inferred from the filename.
    static func fenceLanguage(for url: URL) -> String {
        let name = url.lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") { return "bash" }
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "markdown"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "py": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "jsx": return "typescript"
        case "sh", "bash", "zsh": return "bash"
        case "swift": return "swift"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "xml": return "xml"
        case "html", "htm": return "html"
        case "css", "scss": return "css"
        default: return ""
        }
    }

    /// A backtick fence guaranteed longer than the longest backtick run in `body`
    /// (so a file that itself contains ``` blocks can't break out). Minimum 3.
    static func fence(for body: String) -> String {
        var longest = 0, current = 0
        for ch in body {
            if ch == "`" { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func xmlAttrEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the **Test command**.
Expected: all `ContextAssembler*` tests PASS, plus the pre-existing suite stays green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Document/ContextAssembler.swift Tests/LumeKitTests/ContextAssemblerTests.swift
git commit -m "feat: add ContextAssembler (xml/markdown wrapping + token estimate)"
```

---

## Task 3: SecretDetector

**Files:**
- Create: `Sources/LumeKit/Document/SecretDetector.swift`
- Test: `Tests/LumeKitTests/SecretDetectorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LumeKitTests/SecretDetectorTests.swift
import Testing
import Foundation
@testable import LumeKit

@Test func flagsEnvFamily() {
    #expect(SecretDetector.isSensitive(".env"))
    #expect(SecretDetector.isSensitive(".env.local"))
    #expect(SecretDetector.isSensitive(".env.production"))
}

@Test func flagsKeysAndCredentials() {
    #expect(SecretDetector.isSensitive("server.pem"))
    #expect(SecretDetector.isSensitive("id_rsa"))
    #expect(SecretDetector.isSensitive("my-secret.txt"))
    #expect(SecretDetector.isSensitive("aws_credentials"))
}

@Test func doesNotFlagOrdinaryConfig() {
    #expect(!SecretDetector.isSensitive("CLAUDE.md"))
    #expect(!SecretDetector.isSensitive("config.json"))
    #expect(!SecretDetector.isSensitive("README.md"))
}

@Test func sensitiveFilesFiltersURLs() {
    let urls = [
        URL(fileURLWithPath: "/p/CLAUDE.md"),
        URL(fileURLWithPath: "/p/.env"),
        URL(fileURLWithPath: "/p/key.pem"),
    ]
    #expect(SecretDetector.sensitiveFiles(in: urls).map(\.lastPathComponent) == [".env", "key.pem"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the **Test command**.
Expected: compile failure — `SecretDetector` is undefined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LumeKit/Document/SecretDetector.swift
import Foundation

/// Flags filenames that likely contain secrets, so the UI can warn before
/// their *contents* are copied into a chatbot paste.
public enum SecretDetector {

    public static func sensitiveFiles(in urls: [URL]) -> [URL] {
        urls.filter { isSensitive($0.lastPathComponent) }
    }

    public static func isSensitive(_ filename: String) -> Bool {
        if filename == ".env" || filename.hasPrefix(".env.") { return true }
        let lower = filename.lowercased()
        if lower.hasSuffix(".pem") { return true }
        if lower == "id_rsa" || lower.hasPrefix("id_rsa") { return true }
        if lower.contains("secret") || lower.contains("credential") { return true }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the **Test command**.
Expected: all `SecretDetector*` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Document/SecretDetector.swift Tests/LumeKitTests/SecretDetectorTests.swift
git commit -m "feat: add SecretDetector for secret-aware copy warnings"
```

---

## Task 4: ContextBundle model + schema registration

**Files:**
- Create: `Sources/LumeKit/Library/ContextBundle.swift`
- Modify: `Sources/Lume/LumeApp.swift:12`
- Test: `Tests/LumeKitTests/LibraryStoreBundleTests.swift` (model-persistence test; CRUD added in Task 5)

- [ ] **Step 1: Write a failing persistence test**

```swift
// Tests/LumeKitTests/LibraryStoreBundleTests.swift
import Testing
import SwiftData
@testable import LumeKit

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Favorite.self, Tag.self, FileMeta.self, Bookmark.self, Scan.self, ContextBundle.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

@MainActor @Test func bundleModelPersistsFields() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext

    let bundle = ContextBundle(name: "Prod context", paths: ["/p/CLAUDE.md", "/p/.env"])
    context.insert(bundle)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ContextBundle>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.name == "Prod context")
    #expect(fetched.first?.paths == ["/p/CLAUDE.md", "/p/.env"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the **Test command**.
Expected: compile failure — `ContextBundle` is undefined.

- [ ] **Step 3: Create the model**

```swift
// Sources/LumeKit/Library/ContextBundle.swift
import Foundation
import SwiftData

/// A saved set of files whose *contents* can be re-copied as LLM context.
@Model public final class ContextBundle {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Ordered POSIX paths of the files in this bundle.
    public var paths: [String]
    public var sortIndex: Int = 0
    public var dateAdded: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String,
        paths: [String],
        sortIndex: Int = 0,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.name = name
        self.paths = paths
        self.sortIndex = sortIndex
        self.dateAdded = dateAdded
    }
}
```

- [ ] **Step 4: Register the model in the app schema**

In `Sources/Lume/LumeApp.swift`, line 12, add `ContextBundle.self`:

```swift
let schema = Schema([Favorite.self, Bookmark.self, Tag.self, FileMeta.self, Scan.self, ContextBundle.self])
```

- [ ] **Step 5: Run test to verify it passes**

Run the **Test command**.
Expected: `bundleModelPersistsFields` PASSES; existing suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/Library/ContextBundle.swift Sources/Lume/LumeApp.swift Tests/LumeKitTests/LibraryStoreBundleTests.swift
git commit -m "feat: add ContextBundle @Model and register it in the schema"
```

---

## Task 5: LibraryStore bundle CRUD

**Files:**
- Modify: `Sources/LumeKit/Library/LibraryStore.swift` (append a `// MARK: - Bundles` section after the `// MARK: - Scans` section, before the final closing brace)
- Test: `Tests/LumeKitTests/LibraryStoreBundleTests.swift` (add a CRUD test)

- [ ] **Step 1: Add a failing CRUD test**

Append to `Tests/LumeKitTests/LibraryStoreBundleTests.swift`:

```swift
@MainActor @Test func bundleCRUDViaStore() throws {
    let container = try makeContainer()
    defer { withExtendedLifetime(container) {} }
    let store = LibraryStore(context: container.mainContext)

    let a = store.addBundle(name: "A", paths: ["/x/CLAUDE.md"])
    let b = store.addBundle(name: "B", paths: ["/y/.env"])
    #expect(store.bundles().map(\.name) == ["A", "B"])
    #expect(b.sortIndex == 1)

    store.renameBundle(a, to: "A2")
    store.setBundlePaths(["/x/CLAUDE.md", "/x/memory.md"], for: a)
    let updated = store.bundles().first { $0.id == a.id }
    #expect(updated?.name == "A2")
    #expect(updated?.paths == ["/x/CLAUDE.md", "/x/memory.md"])

    store.removeBundle(b)
    #expect(store.bundles().map(\.name) == ["A2"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the **Test command**.
Expected: compile failure — `addBundle`/`bundles`/etc. are undefined.

- [ ] **Step 3: Implement the CRUD section**

In `Sources/LumeKit/Library/LibraryStore.swift`, add before the final closing `}` (after `removeScan`):

```swift
    // MARK: - Bundles

    @discardableResult
    public func addBundle(name: String, paths: [String]) -> ContextBundle {
        let bundle = ContextBundle(name: name, paths: paths, sortIndex: bundles().count)
        context.insert(bundle)
        try? context.save()
        return bundle
    }

    public func bundles() -> [ContextBundle] {
        (try? context.fetch(
            FetchDescriptor<ContextBundle>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    public func renameBundle(_ bundle: ContextBundle, to name: String) {
        bundle.name = name
        try? context.save()
    }

    public func setBundlePaths(_ paths: [String], for bundle: ContextBundle) {
        bundle.paths = paths
        try? context.save()
    }

    public func removeBundle(_ bundle: ContextBundle) {
        context.delete(bundle)
        try? context.save()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the **Test command**.
Expected: `bundleCRUDViaStore` PASSES; full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Library/LibraryStore.swift Tests/LumeKitTests/LibraryStoreBundleTests.swift
git commit -m "feat: add ContextBundle CRUD to LibraryStore"
```

---

## Task 6: AppState — context copy + bundle state + routing

Wires the LumeKit logic into app state. (No unit test — `AppState` lives in the app target, not the test bundle; verified by build here and manually in later tasks. All heavy logic is already tested in Tasks 2/3/5.)

**Files:**
- Modify: `Sources/Lume/AppState.swift`

- [ ] **Step 1: Add context-format preference + bundle state properties**

Near the other `private(set) var scans...` / scan state declarations (around line 86–100), add:

```swift
    // MARK: - Context bundles state

    static let contextFormatKey = "lume.contextFormat"

    /// Persisted XML/Markdown choice for "Copy as Context".
    var contextFormat: ContextFormat =
        ContextFormat(rawValue: UserDefaults.standard.string(forKey: AppState.contextFormatKey) ?? "") ?? .xml {
        didSet { UserDefaults.standard.set(contextFormat.rawValue, forKey: AppState.contextFormatKey) }
    }

    /// Files staged for copy that include secrets, awaiting user confirmation.
    /// Non-nil drives the secret-confirmation dialog.
    var pendingContextCopy: [URL]?

    private(set) var bundles: [ContextBundle] = []
    /// When non-nil, the detail pane shows this bundle (see ContentView routing).
    var activeBundle: ContextBundle?
```

- [ ] **Step 2: Refresh bundles where scans are loaded**

Find the line in `attach(library:)` that sets `scans = library.scans()` (around line 150) and add directly beneath it:

```swift
        bundles = library.bundles()
```

- [ ] **Step 3: Add the context-copy methods**

Add near the existing `writeToPasteboard` / `copyTicked*` helpers (around line 966–978):

```swift
    // MARK: - Copy as Context

    /// Copy the given files' CONTENTS as one LLM-pasteable blob. If any file
    /// looks like a secret, stage a confirmation instead of copying immediately.
    func copyAsContext(urls: [URL]) {
        let unique = NSOrderedSet(array: urls).array as! [URL]
        guard !unique.isEmpty else { return }
        if SecretDetector.sensitiveFiles(in: unique).isEmpty {
            performContextCopy(unique)
        } else {
            pendingContextCopy = unique
        }
    }

    /// Copy the current Scan triage ticked set as context.
    func copyTickedAsContext() { copyAsContext(urls: tickedURLs) }

    func confirmPendingContextCopy() {
        if let urls = pendingContextCopy { performContextCopy(urls) }
        pendingContextCopy = nil
    }

    func cancelPendingContextCopy() { pendingContextCopy = nil }

    private func performContextCopy(_ urls: [URL]) {
        let assembled = ContextAssembler.assemble(urls, format: contextFormat)
        writeToPasteboard(assembled.text)
    }
```

- [ ] **Step 4: Add bundle CRUD + open/close methods**

Add a new section (e.g. just after the scan methods, near `closeScan`):

```swift
    // MARK: - Bundles

    /// Create a bundle from the current selection and open it.
    func createBundleFromSelection() {
        let paths = selectedURLs.map(\.path)
        guard !paths.isEmpty, let library else { return }
        let bundle = library.addBundle(name: "Bundle \(bundles.count + 1)", paths: paths)
        bundles = library.bundles()
        openBundle(bundle)
    }

    func addPaths(_ paths: [String], to bundle: ContextBundle) {
        guard let library else { return }
        let merged = NSOrderedSet(array: bundle.paths + paths).array as! [String]
        library.setBundlePaths(merged, for: bundle)
        bundles = library.bundles()
    }

    func removePath(_ path: String, from bundle: ContextBundle) {
        guard let library else { return }
        library.setBundlePaths(bundle.paths.filter { $0 != path }, for: bundle)
        bundles = library.bundles()
    }

    func renameBundle(_ bundle: ContextBundle, to name: String) {
        guard let library else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.renameBundle(bundle, to: trimmed)
        bundles = library.bundles()
    }

    func deleteBundle(_ bundle: ContextBundle) {
        guard let library else { return }
        if activeBundle?.id == bundle.id { closeBundle() }
        library.removeBundle(bundle)
        bundles = library.bundles()
    }

    /// Show a bundle in the detail pane (supersedes any active scan).
    func openBundle(_ bundle: ContextBundle) {
        if activeScan != nil { closeScan() }
        activeBundle = bundle
    }

    func closeBundle() { activeBundle = nil }
```

- [ ] **Step 5: Make file-open and scan-run dismiss an active bundle**

So opening a file or running a scan switches the detail pane away from a bundle (mirrors the shipped scan-dismiss fix).

In the file-open method `choose(_:)` (search for `func choose`), add at the top of the body:

```swift
        if activeBundle != nil { closeBundle() }
```

In `runScan(_:)` (around line 919), add near the top (alongside where it sets `activeScan = scan`):

```swift
        if activeBundle != nil { closeBundle() }
```

- [ ] **Step 6: Verify it builds**

Run the **Build command**.
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/Lume/AppState.swift
git commit -m "feat: AppState context-copy, bundle state/CRUD, and detail routing"
```

---

## Task 7: "Copy as Context" button in Scan triage

**Files:**
- Modify: `Sources/Lume/Scans/ScanTriageView.swift` (the `actionBar`, around line 83–101)

- [ ] **Step 1: Add the button**

In `actionBar`, between the "Copy Paths" button and the "Copy as Prompt" button, add:

```swift
            Button { app.copyTickedAsContext() } label: {
                Label("Copy as Context", systemImage: "doc.text")
            }
            .disabled(app.tickedURLs.isEmpty)
```

- [ ] **Step 2: Verify it builds**

Run the **Build command**.
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Lume/Scans/ScanTriageView.swift
git commit -m "feat: Copy as Context action in Scan triage"
```

---

## Task 8: Context command menu + secret confirmation dialog

**Files:**
- Modify: `Sources/Lume/LumeCommands.swift` (add a `CommandMenu("Context")`)
- Modify: `Sources/Lume/ContentView.swift` (host the secret `.confirmationDialog`)

- [ ] **Step 1: Add the Context command menu**

In `Sources/Lume/LumeCommands.swift`, add a new `CommandMenu` (e.g. after the existing `CommandMenu("Navigate")` block):

```swift
        CommandMenu("Context") {
            Button("Copy as Context") { app.copyAsContext(urls: app.selectedURLs) }
                .keyboardShortcut("c", modifiers: [.control, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("New Bundle from Selection…") { app.createBundleFromSelection() }
                .disabled(app.selectedURLs.isEmpty)
            Menu("Add Selection to Bundle") {
                ForEach(app.bundles, id: \.id) { bundle in
                    Button(bundle.name) {
                        app.addPaths(app.selectedURLs.map(\.path), to: bundle)
                    }
                }
            }
            .disabled(app.bundles.isEmpty || app.selectedURLs.isEmpty)
            Divider()
            Picker("Format", selection: Binding(
                get: { app.contextFormat },
                set: { app.contextFormat = $0 }
            )) {
                ForEach(ContextFormat.allCases, id: \.self) { fmt in
                    Text(fmt.label).tag(fmt)
                }
            }
        }
```

> Note: if `LumeCommands.swift` doesn't already `import LumeKit`, add it at the top so `ContextFormat` resolves.

- [ ] **Step 2: Host the secret confirmation dialog**

In `Sources/Lume/ContentView.swift`, attach a `.confirmationDialog` to the top-level content view (the same view that reads `app`). Add this modifier to the outermost view in `body`:

```swift
        .confirmationDialog(
            "This selection includes secrets (e.g. .env). Copy their contents anyway?",
            isPresented: Binding(
                get: { app.pendingContextCopy != nil },
                set: { if !$0 { app.cancelPendingContextCopy() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy Anyway", role: .destructive) { app.confirmPendingContextCopy() }
            Button("Cancel", role: .cancel) { app.cancelPendingContextCopy() }
        }
```

- [ ] **Step 3: Verify it builds**

Run the **Build command**.
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/LumeCommands.swift Sources/Lume/ContentView.swift
git commit -m "feat: Context menu (copy/new bundle/format) + secret confirm dialog"
```

---

## Task 9: Bundles sidebar region + BundleView detail pane

**Files:**
- Create: `Sources/Lume/Bundles/BundleView.swift`
- Modify: `Sources/Lume/SidebarView.swift` (add `BundlesRegion`, place it after `ScansRegion()` near line 12, and define the struct after `ScansRegion`)
- Modify: `Sources/Lume/ContentView.swift` (route to `BundleView` when `activeBundle != nil`)

- [ ] **Step 1: Create BundleView**

```swift
// Sources/Lume/Bundles/BundleView.swift
import SwiftUI
import AppKit
import LumeKit

/// Detail pane for an open ContextBundle: editable name, file list with
/// missing-file markers, a token estimate, and a "Copy as Context" button.
struct BundleView: View {
    @Environment(AppState.self) private var app
    @State private var nameDraft = ""
    @State private var tokenEstimate = 0

    private var bundle: ContextBundle? { app.activeBundle }

    /// URLs in the bundle that still exist on disk.
    private var existingURLs: [URL] {
        (bundle?.paths ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            fileList
            actionBar
        }
        .onAppear { nameDraft = bundle?.name ?? "" }
        .task(id: bundle?.paths) { recomputeEstimate() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
            TextField("Bundle name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.headline)
                .onSubmit { if let b = bundle { app.renameBundle(b, to: nameDraft) } }
            Spacer()
            Button { app.closeBundle() } label: { Label("Close", systemImage: "xmark") }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var fileList: some View {
        List {
            ForEach(bundle?.paths ?? [], id: \.self) { path in
                let url = URL(fileURLWithPath: path)
                let exists = FileManager.default.fileExists(atPath: path)
                HStack(spacing: 8) {
                    Image(systemName: exists ? "doc.text" : "exclamationmark.triangle.fill")
                        .foregroundStyle(exists ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).font(.body)
                            .foregroundStyle(exists ? .primary : .secondary)
                        Text(exists ? (path as NSString).abbreviatingWithTildeInPath : "missing — \(path)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        if let b = bundle { app.removePath(path, from: b) }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
        }
        .overlay {
            if (bundle?.paths ?? []).isEmpty {
                ContentUnavailableView("Empty Bundle", systemImage: "shippingbox",
                    description: Text("Add files via “New Bundle from Selection” or the Context menu."))
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text("~\(tokenEstimate) tokens · \(existingURLs.count) files")
                .foregroundStyle(.secondary)
            Spacer()
            Button { app.copyAsContext(urls: existingURLs) } label: {
                Label("Copy as Context", systemImage: "doc.on.clipboard")
            }
            .disabled(existingURLs.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func recomputeEstimate() {
        tokenEstimate = ContextAssembler.assemble(existingURLs, format: app.contextFormat).tokenEstimate
    }
}
```

- [ ] **Step 2: Add the BundlesRegion to the sidebar**

In `Sources/Lume/SidebarView.swift`, add `BundlesRegion()` right after `ScansRegion()` (near line 12):

```swift
                    ScansRegion()
                    BundlesRegion()
```

Then define the struct just after the `ScansRegion` struct (after its closing `}`, near line 156):

```swift
private struct BundlesRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            if app.bundles.isEmpty {
                Text("Save a set of files to re-copy as LLM context")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.bundles, id: \.id) { bundle in
                    Button {
                        app.openBundle(bundle)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                            Text(bundle.name).lineLimit(1)
                            Spacer()
                            Text("\(bundle.paths.count)")
                                .font(.caption).foregroundStyle(.tertiary)
                            if app.activeBundle?.id == bundle.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { app.openBundle(bundle) }
                        Button("Delete", role: .destructive) { app.deleteBundle(bundle) }
                    }
                }
            }
        } header: {
            Text("Bundles")
        }
    }
}
```

- [ ] **Step 3: Route the detail pane to BundleView**

In `Sources/Lume/ContentView.swift` (around line 44), insert a bundle branch between the scan branch and the `selectedURL` branch:

```swift
        if app.activeScan != nil {
            ScanTriageView()
        } else if app.activeBundle != nil {
            BundleView()
        } else if let url = app.selectedURL {
```

(Keep the rest of that `if/else` chain unchanged.)

- [ ] **Step 4: Verify it builds**

Run the **Build command**.
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lume/Bundles/BundleView.swift Sources/Lume/SidebarView.swift Sources/Lume/ContentView.swift
git commit -m "feat: Bundles sidebar region and BundleView detail pane"
```

---

## Task 10: Full-suite verification + manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run the **Test command**.
Expected: all suites PASS (the pre-existing ~122 tests plus the new `ContextAssembler`, `SecretDetector`, and `ContextBundle` tests).

- [ ] **Step 2: Build the app**

Run the **Build command**.
Expected: build succeeds with no warnings introduced by these changes.

- [ ] **Step 3: Manual smoke test** (the parts unit tests can't cover)

Launch the app and verify:
1. Select 2–3 files in the browser → **Context ▸ Copy as Context** (⌃⌘C) → paste elsewhere → contents are wrapped in `<documents>` (XML default).
2. Switch **Context ▸ Format** to Markdown → copy again → output uses `##` headings + code fences.
3. Include a `.env` in the selection → copying shows the **"includes secrets… copy anyway?"** dialog; Cancel copies nothing, Copy Anyway copies.
4. **Context ▸ New Bundle from Selection…** → a bundle appears in the sidebar **Bundles** region and opens in the detail pane.
5. In `BundleView`: rename the bundle (edit the title field, press Return), remove a file (− button), see the **~N tokens · M files** estimate, click **Copy as Context**.
6. Delete a file on disk that's in a bundle → reopen the bundle → it shows a **missing** marker and is excluded from the copy.
7. Run a **Scan** → tick files → the triage action bar's new **Copy as Context** button copies their contents.
8. With a bundle open, click a file in the sidebar → detail pane switches to the file (bundle dismissed); run a scan → switches to triage.

- [ ] **Step 4: Final commit (if any smoke-test fixes were needed)**

```bash
git add -A
git commit -m "fix: Context Bundles smoke-test corrections"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** Copy-as-context contents (Task 2/7/8), XML+Markdown toggle (Task 1/2/8), token estimate (Task 2, shown in Task 9), saved bundles model+CRUD+UI (Tasks 4/5/6/9), secret warning (Tasks 3/6/8), unreadable/missing-file handling (Task 2 + Task 9 markers). All spec sections map to a task.
- **Type consistency:** `ContextFormat`, `AssembledContext`, `ContextAssembler.assemble`, `SecretDetector.sensitiveFiles/isSensitive`, `ContextBundle`, and the `LibraryStore` methods (`addBundle`/`bundles`/`renameBundle`/`setBundlePaths`/`removeBundle`) and `AppState` methods (`copyAsContext`/`copyTickedAsContext`/`confirmPendingContextCopy`/`cancelPendingContextCopy`/`openBundle`/`closeBundle`/`createBundleFromSelection`/`addPaths`/`removePath`/`renameBundle`/`deleteBundle`) are referenced consistently across tasks.
- **Deferred (followups, per spec):** real tokenizer, large-file truncation, drag-reorder within a bundle, redact-secret-values mode, XML `</document>`-in-content escaping (rare; Markdown path already fences safely).
