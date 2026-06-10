# Remote File Sources + SSH Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect Lume to a remote system over SSH, browse its files in the sidebar, and make safe atomic edits to remote text/config files using the existing editors.

**Architecture:** A source-agnostic `FileSource` protocol (async list/read/write/stat) lands in LumeKit with a `LocalFileSource` (wrapping today's `FileService`/`TextDocument` behavior unchanged) and an `SSHFileSource` that shells out to the system's `ssh`/`sftp` via a testable `CommandRunning` seam. Connection reuse comes from ssh `ControlMaster` multiplexing; each operation is an `sftp -b -` batch over the shared master. The app gains a sidebar source switcher, a remote tree with go-to-path + per-host recents, and remote branches in `AppState.select/save`. Local code paths (FileSystemCache, favorites, tags, scans, file-ops, watcher) are untouched.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, Swift Testing (`import Testing`, `#expect`), XcodeGen, system `/usr/bin/ssh` + `/usr/bin/sftp`. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-06-10-ssh-remote-file-sources-design.md`

**Documented deviations from the spec** (simplifications, same UX — flag to the user if they object):
1. *Persistence:* manual connections + per-host recents are stored as JSON in `~/Library/Application Support/Lume/connections.json` via a new `ConnectionStore`, **not** as a SwiftData model. The library schema has delicate migration constraints (see comments in `Sources/LumeKit/Library/Models.swift`); connections are an independent concern and don't need relationships.
2. *Transport:* instead of one persistent interactive `sftp` process fed over stdin, each operation runs a short-lived `sftp -q -b -` batch that multiplexes over the ssh `ControlMaster` socket. Auth still happens once; per-op channel setup over an established master is milliseconds, and there's no long-lived child process to babysit.
3. *AppState placement:* remote state + methods go directly into `AppState.swift` under a `// MARK: - Remote source (SSH)` section (not an extension file), because they need the existing `private` members (`loadedText`, `selectionGeneration`, `loadTask`).
4. *Local adoption depth:* `LocalFileSource` ships with parity tests, but the local editor/tree keep calling `TextDocument`/`FileSystemCache` directly — only the remote paths run through `FileSource`. The spec's "route the local editor through the abstraction with no visible change" step is deferred to the GitHub sub-project, which actually needs it; doing it now would be a risk with zero payoff. (`selectRemote` is a structural sibling of `select`, so the eventual unification is mechanical.)

**Build/test commands** (used throughout; run from repo root):

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

### Task 1: Source identity types (`SourceID`, `ResourceRef`, `ResourceMeta`, `ResourceNode`)

**Files:**
- Create: `Sources/LumeKit/Sources/ResourceTypes.swift`
- Test: `Tests/LumeKitTests/ResourceTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LumeKit

struct ResourceTypesTests {
    @Test func refNameIsLastPathComponent() {
        let ref = ResourceRef(sourceID: .ssh(alias: "web1"), path: "/etc/nginx/nginx.conf")
        #expect(ref.name == "nginx.conf")
    }

    @Test func nodeIdentityIsItsRef() {
        let ref = ResourceRef(sourceID: .local, path: "/tmp/a.md")
        let node = ResourceNode(ref: ref, isDirectory: false)
        #expect(node.id == ref)
        #expect(node.name == "a.md")
        #expect(node.children == nil)
    }

    @Test func sourceIDsDistinguishHosts() {
        #expect(SourceID.ssh(alias: "a") != SourceID.ssh(alias: "b"))
        #expect(SourceID.local == SourceID.local)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:'LumeKitTests/ResourceTypesTests'` (after `xcodegen generate`)
Expected: BUILD FAILS — `cannot find 'ResourceRef' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Which backend a resource lives in. `.local` is the on-disk workspace;
/// `.ssh` is a connected remote host (keyed by its alias/nickname).
public enum SourceID: Hashable, Sendable {
    case local
    case ssh(alias: String)
}

/// Identifies a resource within some source — replaces "everything is a
/// local URL" for code that must work across local and remote backends.
public struct ResourceRef: Hashable, Sendable {
    public let sourceID: SourceID
    public let path: String          // absolute path within the source

    public init(sourceID: SourceID, path: String) {
        self.sourceID = sourceID
        self.path = path
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Best-effort metadata for one resource (what `ls -la` / `stat` can tell us).
public struct ResourceMeta: Equatable, Sendable {
    public let isDirectory: Bool
    public let size: Int64?
    public let mode: UInt16?         // POSIX permission bits when known

    public init(isDirectory: Bool, size: Int64? = nil, mode: UInt16? = nil) {
        self.isDirectory = isDirectory
        self.size = size
        self.mode = mode
    }
}

/// A node in a source's tree — `FileNode` generalized. `children == nil`
/// means "not a directory" or "directory not yet expanded" (same lazy
/// contract the local sidebar uses).
public struct ResourceNode: Identifiable, Equatable, Sendable {
    public let ref: ResourceRef
    public let isDirectory: Bool
    public var children: [ResourceNode]?

    public init(ref: ResourceRef, isDirectory: Bool, children: [ResourceNode]? = nil) {
        self.ref = ref
        self.isDirectory = isDirectory
        self.children = children
    }

    public var id: ResourceRef { ref }
    public var name: String { ref.name }
    public var kind: FileKind { FileKind.detect(filename: name) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/Sources/ResourceTypes.swift Tests/LumeKitTests/ResourceTypesTests.swift
git commit -m "feat: source-agnostic resource identity types (SourceID, ResourceRef, ResourceNode)"
```

---

### Task 2: `FileSource` protocol + `LocalFileSource` with parity tests

**Files:**
- Create: `Sources/LumeKit/Sources/FileSource.swift`
- Create: `Sources/LumeKit/Sources/LocalFileSource.swift`
- Test: `Tests/LumeKitTests/LocalFileSourceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct LocalFileSourceTests {
    /// Builds a fixture dir: visible files, a dotfile, .env, node_modules, a subdir.
    private func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        return dir
    }

    @Test func listMatchesFileServiceEnumeration() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LocalFileSource()
        let viaSource = try await source.list(dir.path, includeHidden: false)
        let viaService = try FileService().enumerate(dir, includeHidden: false)
        #expect(viaSource.map(\.name) == viaService.map(\.name))
        #expect(viaSource.map(\.isDirectory) == viaService.map(\.isDirectory))
        // Folders first, .env visible, dotfile + node_modules filtered:
        #expect(viaSource.map(\.name) == ["sub", ".env", "alpha.md"])
    }

    @Test func readWriteRoundtrip() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("alpha.md").path
        let source = LocalFileSource()
        try await source.write("hello remote world", to: file)
        let text = try await source.read(file)
        #expect(text == "hello remote world")
    }

    @Test func statReportsDirectoryAndSize() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LocalFileSource()
        let dirMeta = try await source.stat(dir.appendingPathComponent("sub").path)
        #expect(dirMeta.isDirectory)
        let fileMeta = try await source.stat(dir.appendingPathComponent("alpha.md").path)
        #expect(!fileMeta.isDirectory)
        #expect(fileMeta.size == 1)
        #expect(fileMeta.mode != nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'LocalFileSource' in scope`

- [ ] **Step 3: Write `FileSource.swift`**

```swift
import Foundation

/// A backend that can list, read, and write text resources. Local disk and
/// SSH hosts both implement this; the editor and (remote) tree code work
/// against it instead of assuming local URLs.
public protocol FileSource: Sendable {
    var id: SourceID { get }
    /// Children of `path`, filtered/sorted with the same rules as the local
    /// sidebar (ignored names, dotfile policy, folders first).
    func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode]
    /// The resource's contents as UTF-8 text.
    func read(_ path: String) async throws -> String
    /// Replace the resource's contents atomically (a reader never observes a
    /// partial write), preserving its permissions.
    func write(_ text: String, to path: String) async throws
    func stat(_ path: String) async throws -> ResourceMeta
}
```

- [ ] **Step 4: Write `LocalFileSource.swift`**

```swift
import Foundation

/// `FileSource` over the local disk. Wraps the existing `FileService`
/// enumeration rules and `TextDocument` coordinated load/save so behavior is
/// identical to the pre-abstraction code paths.
public struct LocalFileSource: FileSource {
    public let id: SourceID = .local
    private let files: FileServicing

    public init(files: FileServicing = FileService()) {
        self.files = files
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let url = URL(fileURLWithPath: path)
        return try files.enumerate(url, includeHidden: includeHidden).map { node in
            ResourceNode(
                ref: ResourceRef(sourceID: .local, path: node.url.path),
                isDirectory: node.isDirectory
            )
        }
    }

    public func read(_ path: String) async throws -> String {
        try await TextDocument.load(URL(fileURLWithPath: path)).text
    }

    public func write(_ text: String, to path: String) async throws {
        let url = URL(fileURLWithPath: path)
        try await Task.detached(priority: .userInitiated) {
            try TextDocument(url: url, text: text).save()
        }.value
    }

    public func stat(_ path: String) async throws -> ResourceMeta {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let type = attrs[.type] as? FileAttributeType
        return ResourceMeta(
            isDirectory: type == .typeDirectory,
            size: (attrs[.size] as? NSNumber)?.int64Value,
            mode: (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        )
    }
}
```

- [ ] **Step 5: Run tests** — Expected: PASS (3 tests). Also run the full suite to confirm nothing regressed.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/Sources/ Tests/LumeKitTests/LocalFileSourceTests.swift
git commit -m "feat: FileSource protocol + LocalFileSource with parity tests"
```

---

### Task 3: `SSHError` + `SSHHost` (pure types, stderr→error mapping)

**Files:**
- Create: `Sources/LumeKit/SSH/SSHError.swift`
- Create: `Sources/LumeKit/SSH/SSHHost.swift`
- Test: `Tests/LumeKitTests/SSHErrorTests.swift`, `Tests/LumeKitTests/SSHHostTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/LumeKitTests/SSHErrorTests.swift`:

```swift
import Testing
import Foundation
@testable import LumeKit

struct SSHErrorTests {
    private func map(_ stderr: String, path: String? = nil) -> SSHError {
        SSHError.map(exitCode: 1, stderr: Data(stderr.utf8), path: path)
    }

    @Test func authBeforeGenericPermissionDenied() {
        // ssh's auth failure also contains "Permission denied" — must map to auth.
        #expect(map("manu@web1: Permission denied (publickey,password).") == .authFailed)
    }

    @Test func sftpPermissionDeniedIsFileLevel() {
        #expect(map(#"remote open("/etc/shadow"): Permission denied"#, path: "/etc/shadow")
                == .permissionDenied(path: "/etc/shadow"))
    }

    @Test func notFound() {
        #expect(map("Couldn't stat remote file: No such file or directory", path: "/nope")
                == .notFound(path: "/nope"))
    }

    @Test func unreachableHostsAreConnectFailures() {
        #expect(map("ssh: connect to host web1 port 22: Connection refused")
                == .connectFailed(detail: "ssh: connect to host web1 port 22: Connection refused"))
        #expect(map("ssh: Could not resolve hostname web1: nodename nor servname provided")
                == .connectFailed(detail: "ssh: Could not resolve hostname web1: nodename nor servname provided"))
    }

    @Test func droppedMasterIsConnectionLost() {
        #expect(map("Connection closed by remote host") == .connectionLost)
        #expect(map("mux_client_request_session: session request failed") == .connectionLost)
    }

    @Test func unknownFallsBackToProtocolFailure() {
        #expect(map("something nobody expected") == .protocolFailure(detail: "something nobody expected"))
    }

    @Test func messagesAreHuman() {
        #expect(SSHError.permissionDenied(path: "/etc/nginx/nginx.conf").userMessage
                == "The remote user can't write /etc/nginx/nginx.conf.")
        #expect(SSHError.authFailed.userMessage.contains("Authentication failed"))
    }
}
```

`Tests/LumeKitTests/SSHHostTests.swift`:

```swift
import Testing
@testable import LumeKit

struct SSHHostTests {
    @Test func configAliasHostHasBareDestinationAndNoFlags() {
        let host = SSHHost(alias: "web1")
        #expect(host.destination == "web1")
        #expect(host.flags(portFlag: "-p").isEmpty)
    }

    @Test func manualHostBuildsDestinationAndFlags() {
        let host = SSHHost(alias: "prod", hostname: "10.0.0.5", user: "deploy",
                           port: 2222, identityFile: "/Users/manu/.ssh/id_prod")
        #expect(host.destination == "deploy@10.0.0.5")
        #expect(host.flags(portFlag: "-p") == ["-p", "2222", "-i", "/Users/manu/.ssh/id_prod"])
        #expect(host.flags(portFlag: "-P") == ["-P", "2222", "-i", "/Users/manu/.ssh/id_prod"])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'SSHError' in scope`

- [ ] **Step 3: Write `SSHError.swift`**

```swift
import Foundation

/// Typed failures from the SSH layer, each with a human message. `map`
/// classifies raw ssh/sftp stderr (the only error channel a subprocess gives us).
public enum SSHError: Error, Equatable, Sendable {
    case connectFailed(detail: String)
    case authFailed
    case timeout(executable: String)
    case permissionDenied(path: String)
    case notFound(path: String)
    case connectionLost
    case protocolFailure(detail: String)

    public var userMessage: String {
        switch self {
        case .connectFailed(let detail):
            return "Couldn't connect: \(detail)"
        case .authFailed:
            return "Authentication failed. Check your SSH keys (or add the key to ssh-agent) and try again."
        case .timeout(let executable):
            return "The remote operation timed out (\((executable as NSString).lastPathComponent))."
        case .permissionDenied(let path):
            return "The remote user can't write \(path)."
        case .notFound(let path):
            return "\(path) doesn't exist on the remote."
        case .connectionLost:
            return "Connection lost."
        case .protocolFailure(let detail):
            return "SSH error: \(detail)"
        }
    }

    /// Classify a failed ssh/sftp invocation by its stderr. Order matters:
    /// ssh's auth failure ("Permission denied (publickey…)") must win over the
    /// generic file-level "Permission denied".
    public static func map(exitCode: Int32, stderr: Data, path: String?) -> SSHError {
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission denied (") { return .authFailed }
        if lower.contains("permission denied") { return .permissionDenied(path: path ?? "the file") }
        if lower.contains("no such file") { return .notFound(path: path ?? "the path") }
        if lower.contains("connection refused") || lower.contains("could not resolve")
            || lower.contains("operation timed out") || lower.contains("network is unreachable") {
            return .connectFailed(detail: text)
        }
        if lower.contains("connection closed") || lower.contains("broken pipe")
            || lower.contains("mux_client") || lower.contains("connection reset") {
            return .connectionLost
        }
        return .protocolFailure(detail: text.isEmpty ? "exit code \(exitCode)" : text)
    }
}
```

- [ ] **Step 4: Write `SSHHost.swift`**

```swift
import Foundation

/// One connectable host. A pure-config host carries only `alias` (ssh resolves
/// user/port/keys from ~/.ssh/config); a manual host carries explicit fields.
public struct SSHHost: Codable, Hashable, Sendable, Identifiable {
    public var alias: String         // display name + ControlPath key
    public var hostname: String?     // nil → alias is resolved by ssh config
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public var id: String { alias }

    public init(alias: String, hostname: String? = nil, user: String? = nil,
                port: Int? = nil, identityFile: String? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    /// The destination argument: "user@host" for manual hosts, bare alias otherwise.
    public var destination: String {
        let target = hostname ?? alias
        if let user, !user.isEmpty { return "\(user)@\(target)" }
        return target
    }

    /// Explicit CLI flags. The port flag differs by tool: ssh uses "-p",
    /// sftp uses "-P" — the caller passes the right spelling.
    public func flags(portFlag: String) -> [String] {
        var flags: [String] = []
        if let port { flags += [portFlag, String(port)] }
        if let identityFile, !identityFile.isEmpty { flags += ["-i", identityFile] }
        return flags
    }
}
```

- [ ] **Step 5: Run both suites** — Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/SSH/ Tests/LumeKitTests/SSHErrorTests.swift Tests/LumeKitTests/SSHHostTests.swift
git commit -m "feat: SSHError taxonomy with stderr mapping + SSHHost descriptor"
```

---

### Task 4: `CommandRunning` seam + `ProcessRunner` + `FakeCommandRunner`

**Files:**
- Create: `Sources/LumeKit/SSH/CommandRunning.swift`
- Create: `Tests/LumeKitTests/FakeCommandRunner.swift` (test support)
- Test: `Tests/LumeKitTests/ProcessRunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/LumeKitTests/ProcessRunnerTests.swift` (real subprocesses — tiny system binaries only):

```swift
import Testing
import Foundation
@testable import LumeKit

struct ProcessRunnerTests {
    @Test func capturesStdoutAndExitCode() async throws {
        let result = try await ProcessRunner().run(
            "/bin/echo", ["hello"], stdin: nil, environment: nil, timeout: 10)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func capturesNonzeroExit() async throws {
        let result = try await ProcessRunner().run(
            "/usr/bin/false", [], stdin: nil, environment: nil, timeout: 10)
        #expect(result.exitCode != 0)
    }

    @Test func feedsStdin() async throws {
        let result = try await ProcessRunner().run(
            "/bin/cat", [], stdin: Data("piped".utf8), environment: nil, timeout: 10)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "piped")
    }

    @Test func timesOutAndThrows() async {
        await #expect(throws: SSHError.timeout(executable: "/bin/sleep")) {
            _ = try await ProcessRunner().run(
                "/bin/sleep", ["5"], stdin: nil, environment: nil, timeout: 0.3)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'ProcessRunner' in scope`

- [ ] **Step 3: Write `CommandRunning.swift`**

```swift
import Foundation

/// The exit state of one finished subprocess.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Subprocess seam for the SSH layer: everything above this protocol is
/// unit-testable with a fake; only `ProcessRunner` touches real processes.
public protocol CommandRunning: Sendable {
    /// Run `executable` with `arguments`; feed `stdin` (then close it); merge
    /// `environment` over the inherited one. Throws `SSHError.timeout` if the
    /// process outlives `timeout` seconds (it gets terminated).
    func run(_ executable: String, _ arguments: [String], stdin: Data?,
             environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: Data?,
                    environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try box.launchAndWait(executable: executable, arguments: arguments,
                                      stdin: stdin, environment: environment, timeout: timeout)
            }.value
        } onCancel: {
            box.terminate()
        }
    }
}

/// Wraps `Process` so termination can be requested across threads.
/// @unchecked: `terminate()` is thread-safe; the lock guards our own fields.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timedOut = false

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
    }

    private func markTimedOutAndTerminate() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
        process?.terminate()
    }

    func launchAndWait(executable: String, arguments: [String], stdin: Data?,
                       environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment {
            p.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        lock.lock(); process = p; lock.unlock()
        try p.run()

        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        // Deadline watchdog — waitUntilExit has no timeout of its own.
        let watchdog = DispatchWorkItem { [weak self] in self?.markTimedOutAndTerminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stderr concurrently so a full pipe buffer (>64 KB) can't
        // deadlock against our sequential stdout read.
        let stderrBox = DataBox()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            stderrDone.signal()
        }
        let stdout = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        stderrDone.wait()
        p.waitUntilExit()
        watchdog.cancel()

        lock.lock()
        let didTimeOut = timedOut
        process = nil
        lock.unlock()
        if didTimeOut { throw SSHError.timeout(executable: executable) }
        return CommandResult(exitCode: p.terminationStatus, stdout: stdout, stderr: stderrBox.data)
    }
}

/// Mutable Data crossing a queue boundary; ordering guaranteed by the semaphore.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
```

- [ ] **Step 4: Write `Tests/LumeKitTests/FakeCommandRunner.swift`** (shared by Tasks 7–9)

```swift
import Foundation
@testable import LumeKit

/// Scripted `CommandRunning` for SSH-layer tests: returns canned results in
/// FIFO order and records every invocation for assertions.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let stdin: String?
    }

    private let lock = NSLock()
    private var queue: [Result<CommandResult, Error>]
    private(set) var calls: [Call] = []

    init(results: [Result<CommandResult, Error>] = []) {
        self.queue = results
    }

    static func ok(_ stdout: String = "") -> Result<CommandResult, Error> {
        .success(CommandResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data()))
    }

    static func fail(_ stderr: String, exitCode: Int32 = 1) -> Result<CommandResult, Error> {
        .success(CommandResult(exitCode: exitCode, stdout: Data(), stderr: Data(stderr.utf8)))
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?,
             environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        lock.lock()
        calls.append(Call(executable: executable, arguments: arguments,
                          stdin: stdin.map { String(decoding: $0, as: UTF8.self) }))
        let next = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        switch next {
        case .success(let result): return result
        case .failure(let error): throw error
        case nil: return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }
}
```

- [ ] **Step 5: Run `ProcessRunnerTests`** — Expected: PASS (4 tests)

- [ ] **Step 6: Commit**

```bash
git add Sources/LumeKit/SSH/CommandRunning.swift Tests/LumeKitTests/FakeCommandRunner.swift Tests/LumeKitTests/ProcessRunnerTests.swift
git commit -m "feat: CommandRunning subprocess seam with ProcessRunner and test fake"
```

---

### Task 5: `SSHConfigParser` (~/.ssh/config host aliases)

**Files:**
- Create: `Sources/LumeKit/SSH/SSHConfigParser.swift`
- Test: `Tests/LumeKitTests/SSHConfigParserTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import LumeKit

struct SSHConfigParserTests {
    @Test func extractsConcreteAliases() {
        let config = """
        # personal boxes
        Host web1
            HostName 10.0.0.5
            User deploy

        Host db1 db2
          Port 2222
        """
        #expect(SSHConfigParser.aliases(in: config) == ["web1", "db1", "db2"])
    }

    @Test func skipsWildcardsNegationsAndComments() {
        let config = """
        Host *
            ServerAliveInterval 60
        Host *.internal !bastion deploy-??
        # Host commented-out
        Host real
        """
        #expect(SSHConfigParser.aliases(in: config) == ["real"])
    }

    @Test func caseInsensitiveKeywordAndTabs() {
        #expect(SSHConfigParser.aliases(in: "host\tlower") == ["lower"])
        #expect(SSHConfigParser.aliases(in: "HOST UPPER") == ["UPPER"])
    }

    @Test func dedupesRepeatedAliases() {
        let config = "Host a\nHost a b"
        #expect(SSHConfigParser.aliases(in: config) == ["a", "b"])
    }

    @Test func followsIncludesOneLevel() {
        let main = """
        Include conf.d/work
        Host top
        """
        let aliases = SSHConfigParser.aliases(configText: main) { path in
            path == "conf.d/work" ? "Host included1\nHost included2" : nil
        }
        #expect(aliases == ["top", "included1", "included2"])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'SSHConfigParser' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Extracts connectable host nicknames from ssh_config text. Lume only needs
/// the aliases for its pick list — ssh itself resolves user/port/keys when we
/// shell out, so everything else in the file is deliberately ignored.
public enum SSHConfigParser {
    /// Concrete `Host` aliases, in file order. Wildcard (`*`, `?`) and negated
    /// (`!`) patterns are option-scoping, not connectable names — skipped.
    public static func aliases(in text: String) -> [String] {
        var result: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.count > 5, line.prefix(4).lowercased() == "host",
                  line[line.index(line.startIndex, offsetBy: 4)] == " "
                    || line[line.index(line.startIndex, offsetBy: 4)] == "\t"
            else { continue }
            let patterns = line.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" })
            for pattern in patterns {
                let alias = String(pattern)
                if alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") { continue }
                if !result.contains(alias) { result.append(alias) }
            }
        }
        return result
    }

    /// Like `aliases(in:)` but follows `Include` directives one level deep via
    /// an injectable reader (the app passes a file reader; tests pass a stub).
    /// Glob patterns in Include paths are passed to the reader verbatim.
    public static func aliases(configText: String,
                               reader: (String) -> String?) -> [String] {
        var combined = configText
        for raw in configText.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 8, line.prefix(7).lowercased() == "include" else { continue }
            let path = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, let included = reader(path) {
                combined += "\n" + included
            }
        }
        return aliases(in: combined)
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/SSH/SSHConfigParser.swift Tests/LumeKitTests/SSHConfigParserTests.swift
git commit -m "feat: SSHConfigParser extracts concrete host aliases (Include-aware)"
```

---

### Task 6: `TreeFilterRules` extraction + `SFTPListingParser`

**Files:**
- Create: `Sources/LumeKit/FileSystem/TreeFilterRules.swift`
- Modify: `Sources/LumeKit/FileSystem/FileService.swift` (use the shared rules)
- Create: `Sources/LumeKit/SSH/SFTPListingParser.swift`
- Test: `Tests/LumeKitTests/SFTPListingParserTests.swift`

- [ ] **Step 1: Extract the visibility rules** (refactor first — existing tests are the net)

Create `Sources/LumeKit/FileSystem/TreeFilterRules.swift`:

```swift
import Foundation

/// Name-level visibility rules shared by every tree backend (local + SSH),
/// extracted from `FileService` so remote listings filter identically.
public enum TreeFilterRules {
    /// Names that are never shown, even with "Show hidden" on — pure noise
    /// the user never curates.
    public static let ignoredNames: Set<String> = [
        ".DS_Store", "node_modules", ".git", ".build", ".svn",
    ]

    /// Whether `name` appears in the tree. `.env*` stays visible regardless
    /// of the hidden toggle (it's a curated config, not noise).
    public static func isVisible(name: String, includeHidden: Bool) -> Bool {
        if ignoredNames.contains(name) { return false }
        if !includeHidden, name.hasPrefix("."), name != ".env", !name.hasPrefix(".env.") {
            return false
        }
        return true
    }
}
```

In `Sources/LumeKit/FileSystem/FileService.swift`, delete the private `ignoredNames` set and replace the two filter checks inside `enumerate`'s `compactMap`:

```swift
        let nodes: [FileNode] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard TreeFilterRules.isVisible(name: name, includeHidden: includeHidden) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileNode(url: url, isDirectory: isDir, children: nil)
        }
```

- [ ] **Step 2: Run the FULL test suite** — Expected: PASS (parity tests from Task 2 + any existing FileService coverage prove the refactor changed nothing)

- [ ] **Step 3: Commit the refactor**

```bash
git add Sources/LumeKit/FileSystem/
git commit -m "refactor: extract TreeFilterRules so local and SSH trees filter identically"
```

- [ ] **Step 4: Write the failing parser tests**

`Tests/LumeKitTests/SFTPListingParserTests.swift`:

```swift
import Testing
@testable import LumeKit

struct SFTPListingParserTests {
    @Test func parsesDirsFilesAndModes() {
        let output = """
        sftp> ls -la /etc/nginx
        drwxr-xr-x    5 root     wheel        4096 Jun  9 10:00 conf.d
        -rw-r--r--    1 root     wheel        2049 Jun  9 10:00 nginx.conf
        -rwxr-x---    1 root     wheel         512 Jan  3  2025 reload.sh
        """
        let entries = SFTPListingParser.parse(output)
        #expect(entries.count == 3)
        #expect(entries[0] == .init(name: "conf.d", isDirectory: true, size: 4096, mode: 0o755))
        #expect(entries[1] == .init(name: "nginx.conf", isDirectory: false, size: 2049, mode: 0o644))
        #expect(entries[2].mode == 0o750)
    }

    @Test func skipsDotDotDotTotalAndEcho() {
        let output = """
        sftp> ls -la .
        drwxr-xr-x    9 manu     staff         288 Jun  9 10:00 .
        drwxr-xr-x    4 manu     staff         128 Jun  9 10:00 ..
        -rw-r--r--    1 manu     staff           5 Jun  9 10:00 real.md
        """
        #expect(SFTPListingParser.parse(output).map(\.name) == ["real.md"])
    }

    @Test func handlesSpacesInNamesAndSymlinks() {
        let output = """
        -rw-r--r--    1 manu     staff          10 Jun  9 10:00 my notes file.md
        lrwxrwxrwx    1 root     wheel          20 Jun  9 10:00 current -> releases/v2
        """
        let entries = SFTPListingParser.parse(output)
        #expect(entries[0].name == "my notes file.md")
        #expect(entries[1].name == "current")
        #expect(!entries[1].isDirectory)   // MVP: symlinks render as files
    }

    @Test func extendedAttributeMarkerTolerated() {
        // macOS sshd: trailing '@' (xattrs) / '+' (ACLs) on the perms column.
        let output = "-rw-r--r--@   1 manu     staff         100 Jun  9 10:00 tagged.md"
        let entries = SFTPListingParser.parse(output)
        #expect(entries.first?.name == "tagged.md")
        #expect(entries.first?.mode == 0o644)
    }

    @Test func parsesPwdOutput() {
        let output = "sftp> pwd\nRemote working directory: /home/manu\n"
        #expect(SFTPListingParser.workingDirectory(in: output) == "/home/manu")
    }
}
```

- [ ] **Step 5: Run to verify failure** — `cannot find 'SFTPListingParser' in scope`

- [ ] **Step 6: Write `Sources/LumeKit/SSH/SFTPListingParser.swift`**

```swift
import Foundation

/// Parses OpenSSH `sftp` batch output: long `ls -la` listings and `pwd`.
/// Batch mode echoes each command as an "sftp> …" line — those, `total`
/// headers, and `.`/`..` are noise and skipped.
public enum SFTPListingParser {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64?
        public let mode: UInt16?

        public init(name: String, isDirectory: Bool, size: Int64?, mode: UInt16?) {
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.mode = mode
        }
    }

    public static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { parseLine(String($0)) }
    }

    /// One long-format line:
    /// `-rw-r--r--    1 root     wheel        2049 Jun  9 10:00 nginx.conf`
    /// Fields 0–7 are fixed; everything after field 7 is the (spaceable) name.
    static func parseLine(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9 else { return nil }
        var perms = fields[0]
        // macOS ls appends '@' (xattrs) or '+' (ACLs) to the mode column.
        if perms.count == 11, perms.hasSuffix("@") || perms.hasSuffix("+") {
            perms = perms.dropLast()
        }
        guard perms.count == 10 else { return nil }
        let typeChar = perms.first!
        guard typeChar == "d" || typeChar == "-" || typeChar == "l" else { return nil }

        var name = String(fields[8])
        if typeChar == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        if name == "." || name == ".." { return nil }

        return Entry(
            name: name,
            isDirectory: typeChar == "d",
            size: Int64(fields[4]),
            mode: parseMode(perms.dropFirst())
        )
    }

    /// "rw-r--r--" → 0o644. Setuid/sticky letters grant the underlying bit
    /// when lowercase ('s'/'t'); uppercase ('S'/'T') means the bit without
    /// execute — close enough for a writability hint.
    static func parseMode(_ rwx: Substring) -> UInt16? {
        guard rwx.count == 9 else { return nil }
        var mode: UInt16 = 0
        for (i, char) in rwx.enumerated() {
            if char == "-" || char == "S" || char == "T" { continue }
            mode |= 1 << (8 - i)
        }
        return mode
    }

    /// Extracts the path from sftp's `pwd` response
    /// ("Remote working directory: /home/manu").
    public static func workingDirectory(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "Remote working directory: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
```

- [ ] **Step 7: Run tests** — Expected: PASS (5 tests)

- [ ] **Step 8: Commit**

```bash
git add Sources/LumeKit/SSH/SFTPListingParser.swift Tests/LumeKitTests/SFTPListingParserTests.swift
git commit -m "feat: SFTP long-listing and pwd output parser"
```

---

### Task 7: `SSHTransport` (ControlMaster lifecycle + sftp batches)

**Files:**
- Create: `Sources/LumeKit/SSH/SSHTransport.swift`
- Test: `Tests/LumeKitTests/SSHTransportTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct SSHTransportTests {
    private func makeTransport(_ runner: FakeCommandRunner,
                               host: SSHHost = SSHHost(alias: "web1")) -> SSHTransport {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHTransportTests-\(UUID().uuidString)")
        return SSHTransport(host: host, runner: runner, controlDir: dir)
    }

    @Test func connectRunsBackgroundedMasterWithControlOptions() async throws {
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        let transport = makeTransport(runner)
        try await transport.connect()
        let call = runner.calls[0]
        #expect(call.executable == "/usr/bin/ssh")
        #expect(call.arguments.contains("ControlMaster=auto"))
        #expect(call.arguments.contains(where: { $0.hasPrefix("ControlPath=") && $0.hasSuffix("web1.sock") }))
        #expect(call.arguments.suffix(2) == ["-fN", "web1"])
    }

    @Test func connectMapsAuthFailure() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("manu@web1: Permission denied (publickey)."),
        ])
        let transport = makeTransport(runner)
        await #expect(throws: SSHError.authFailed) { try await transport.connect() }
    }

    @Test func manualHostFlagsAndDestination() async throws {
        let host = SSHHost(alias: "prod", hostname: "10.0.0.5", user: "deploy", port: 2222)
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok()])
        try await makeTransport(runner, host: host).connect()
        let args = runner.calls[0].arguments
        #expect(args.contains("-p") && args.contains("2222"))
        #expect(args.last == "deploy@10.0.0.5")
    }

    @Test func sftpFeedsBatchOverStdinWithCapitalPortFlag() async throws {
        let host = SSHHost(alias: "prod", hostname: "10.0.0.5", port: 2222)
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok("listing")])
        let out = try await makeTransport(runner, host: host).sftp(["ls -la /etc"])
        #expect(out == "listing")
        let call = runner.calls[0]
        #expect(call.executable == "/usr/bin/sftp")
        #expect(call.stdin == "ls -la /etc\n")
        #expect(call.arguments.contains("-P") && call.arguments.contains("2222"))
        #expect(call.arguments.contains("-b"))
    }

    @Test func sftpReconnectsOnceWhenMasterDied() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("Connection closed by remote host"),  // sftp #1
            FakeCommandRunner.ok(),                                       // reconnect ssh -fN
            FakeCommandRunner.ok("recovered"),                            // sftp #2
        ])
        let out = try await makeTransport(runner).sftp(["pwd"])
        #expect(out == "recovered")
        #expect(runner.calls.map(\.executable) ==
                ["/usr/bin/sftp", "/usr/bin/ssh", "/usr/bin/sftp"])
    }

    @Test func sftpSurfacesPermissionDeniedWithoutRetry() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail(#"remote open("/etc/x"): Permission denied"#),
        ])
        let transport = makeTransport(runner)
        await #expect(throws: SSHError.permissionDenied(path: "/etc/x")) {
            _ = try await transport.sftp(["put a /etc/x"], path: "/etc/x")
        }
        #expect(runner.calls.count == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'SSHTransport' in scope`

- [ ] **Step 3: Write `Sources/LumeKit/SSH/SSHTransport.swift`**

```swift
import Foundation

/// One host's connection: establishes an ssh ControlMaster (auth happens once,
/// natively prompted if needed) and runs sftp batches that multiplex over it.
public actor SSHTransport {
    public let host: SSHHost
    private let runner: CommandRunning
    private let controlDir: URL

    public static var defaultControlDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume/ssh", isDirectory: true)
    }

    public init(host: SSHHost, runner: CommandRunning = ProcessRunner(),
                controlDir: URL = SSHTransport.defaultControlDir) {
        self.host = host
        self.runner = runner
        self.controlDir = controlDir
    }

    private var controlPath: String {
        controlDir.appendingPathComponent("\(host.alias).sock").path
    }

    /// -o options shared by ssh and sftp: every process multiplexes over the
    /// one authenticated master keyed by this host's control socket.
    private var controlOptions: [String] {
        ["-o", "ControlMaster=auto",
         "-o", "ControlPath=\(controlPath)",
         "-o", "ControlPersist=600",
         "-o", "ConnectTimeout=15"]
    }

    /// Establish (or reuse) the master. `-fN` backgrounds after auth, so this
    /// returns once the connection is usable. Generous timeout: the user may
    /// be typing a passphrase into the askpass prompt.
    public func connect() async throws {
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        let args = controlOptions + host.flags(portFlag: "-p") + ["-fN", host.destination]
        let result = try await runner.run("/usr/bin/ssh", args, stdin: nil,
                                          environment: Self.askpassEnvironment(controlDir: controlDir),
                                          timeout: 120)
        guard result.exitCode == 0 else {
            throw SSHError.map(exitCode: result.exitCode, stderr: result.stderr, path: nil)
        }
    }

    /// Run an sftp batch over the master and return its stdout. If the master
    /// died underneath us, reconnect once transparently, then surface errors.
    /// `path` attributes file-level failures (permission denied / not found).
    public func sftp(_ commands: [String], path: String? = nil,
                     timeout: TimeInterval = 30) async throws -> String {
        do {
            return try await sftpOnce(commands, path: path, timeout: timeout)
        } catch SSHError.connectionLost {
            try await connect()
            return try await sftpOnce(commands, path: path, timeout: timeout)
        }
    }

    private func sftpOnce(_ commands: [String], path: String?,
                          timeout: TimeInterval) async throws -> String {
        let batch = commands.joined(separator: "\n") + "\n"
        let args = controlOptions + host.flags(portFlag: "-P")
            + ["-q", "-b", "-", host.destination]
        let result = try await runner.run("/usr/bin/sftp", args, stdin: Data(batch.utf8),
                                          environment: nil, timeout: timeout)
        guard result.exitCode == 0 else {
            throw SSHError.map(exitCode: result.exitCode, stderr: result.stderr, path: path)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Whether the master is still alive (`ssh -O check`).
    public func isAlive() async -> Bool {
        let args = controlOptions + ["-O", "check", host.destination]
        let result = try? await runner.run("/usr/bin/ssh", args, stdin: nil,
                                           environment: nil, timeout: 10)
        return result?.exitCode == 0
    }

    /// Tear down the master (`ssh -O exit`). Best-effort.
    public func disconnect() async {
        let args = controlOptions + ["-O", "exit", host.destination]
        _ = try? await runner.run("/usr/bin/ssh", args, stdin: nil,
                                  environment: nil, timeout: 10)
    }

    /// Native passphrase/password prompting: ssh has no TTY here, so point
    /// SSH_ASKPASS at a tiny osascript helper (written once, chmod 755).
    /// "prefer" lets ssh-agent answer silently when it can.
    static func askpassEnvironment(controlDir: URL) -> [String: String] {
        let script = controlDir.appendingPathComponent("lume-askpass.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            let body = """
            #!/bin/sh
            # Lume's SSH askpass: native dialog for passphrases/passwords.
            PROMPT=$(printf '%s' "$1" | tr '"' "'")
            exec /usr/bin/osascript \
              -e "display dialog \\"$PROMPT\\" default answer \\"\\" with hidden answer with title \\"Lume — SSH\\" buttons {\\"Cancel\\",\\"OK\\"} default button \\"OK\\"" \
              -e 'text returned of result'
            """
            try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
            try? body.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: script.path)
        }
        return ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "prefer"]
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/SSH/SSHTransport.swift Tests/LumeKitTests/SSHTransportTests.swift
git commit -m "feat: SSHTransport — ControlMaster lifecycle, sftp batches, one-shot reconnect"
```

---

### Task 8: `SSHFileSource` — list / read / stat / realpath

**Files:**
- Create: `Sources/LumeKit/SSH/SSHFileSource.swift`
- Test: `Tests/LumeKitTests/SSHFileSourceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct SSHFileSourceTests {
    private func makeSource(_ runner: FakeCommandRunner) -> SSHFileSource {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHFileSourceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = SSHHost(alias: "web1")
        let transport = SSHTransport(host: host, runner: runner,
                                     controlDir: dir.appendingPathComponent("ctl"))
        return SSHFileSource(host: host, transport: transport, tempDir: dir)
    }

    @Test func listFiltersSortsAndBuildsRefs() async throws {
        let listing = """
        sftp> ls -la /srv/app
        drwxr-xr-x  2 u g  96 Jun  9 10:00 .git
        drwxr-xr-x  2 u g  96 Jun  9 10:00 conf
        -rw-r--r--  1 u g  10 Jun  9 10:00 .env
        -rw-r--r--  1 u g  10 Jun  9 10:00 .secret
        -rw-r--r--  1 u g  10 Jun  9 10:00 app.yaml
        """
        let runner = FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])
        let nodes = try await makeSource(runner).list("/srv/app", includeHidden: false)
        // .git ignored always; .secret hidden; folders first; .env visible.
        #expect(nodes.map(\.name) == ["conf", ".env", "app.yaml"])
        #expect(nodes[0].isDirectory)
        #expect(nodes[1].ref == ResourceRef(sourceID: .ssh(alias: "web1"), path: "/srv/app/.env"))
        #expect(runner.calls[0].stdin == "ls -la \"/srv/app\"\n")
    }

    @Test func statSingleFileParsesItsLine() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("-rw-r----- 1 u g 2049 Jun  9 10:00 /etc/app/config.yaml"),
        ])
        let meta = try await makeSource(runner).stat("/etc/app/config.yaml")
        #expect(!meta.isDirectory)
        #expect(meta.size == 2049)
        #expect(meta.mode == 0o640)
    }

    @Test func statDirectoryFallsBackWhenContentsListed() async throws {
        let listing = """
        -rw-r--r-- 1 u g 10 Jun  9 10:00 a.txt
        -rw-r--r-- 1 u g 10 Jun  9 10:00 b.txt
        """
        let meta = try await makeSource(
            FakeCommandRunner(results: [FakeCommandRunner.ok(listing)])).stat("/etc/app")
        #expect(meta.isDirectory)
    }

    @Test func readDownloadsToTempAndReturnsText() async throws {
        let runner = FakeCommandRunner()
        let source = makeSource(runner)
        // The fake runs no real sftp, so pre-create what `get` would download:
        // intercept by checking the call afterward and writing the temp file is
        // impossible mid-call — instead the source must treat a missing temp
        // file as an error. Verify the command shape and the error path here.
        await #expect(throws: SSHError.self) {
            _ = try await source.read("/srv/app/app.yaml")
        }
        let stdin = runner.calls[0].stdin ?? ""
        #expect(stdin.hasPrefix("get \"/srv/app/app.yaml\" \""))
    }

    @Test func realpathParsesPwd() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok("sftp> cd \"/home/manu\"\nsftp> pwd\nRemote working directory: /home/manu\n"),
        ])
        let path = try await makeSource(runner).realpath(".")
        #expect(path == "/home/manu")
        #expect(runner.calls[0].stdin == "cd \".\"\npwd\n")
    }

    @Test func quoteEscapesQuotesAndBackslashes() {
        #expect(SSHFileSource.quote(#"/tmp/we"ird\path"#) == #""/tmp/we\"ird\\path""#)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'SSHFileSource' in scope`

- [ ] **Step 3: Write `Sources/LumeKit/SSH/SSHFileSource.swift`** (list/read/stat/realpath; `write` arrives in Task 9)

```swift
import Foundation

/// `FileSource` over an SSH host. Every operation is an sftp batch through the
/// host's `SSHTransport`; output parsing lives in `SFTPListingParser`.
public actor SSHFileSource: FileSource {
    public nonisolated let id: SourceID
    let transport: SSHTransport
    private let tempDir: URL
    /// Injectable so atomic-write tests get deterministic temp names.
    private let tempSuffix: @Sendable () -> String

    public init(host: SSHHost, transport: SSHTransport,
                tempDir: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumeSSH", isDirectory: true),
                tempSuffix: @escaping @Sendable () -> String = { UUID().uuidString.prefix(8).lowercased() }) {
        self.id = .ssh(alias: host.alias)
        self.transport = transport
        self.tempDir = tempDir
        self.tempSuffix = tempSuffix
    }

    /// Double-quote a path for an sftp batch command (handles spaces; escapes
    /// embedded quotes/backslashes).
    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"\(escaped)\""
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let out = try await transport.sftp(["ls -la \(Self.quote(path))"], path: path)
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        return SFTPListingParser.parse(out)
            .filter { TreeFilterRules.isVisible(name: $0.name, includeHidden: includeHidden) }
            .map { entry in
                ResourceNode(
                    ref: ResourceRef(sourceID: id, path: "\(base)/\(entry.name)"),
                    isDirectory: entry.isDirectory
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }  // folders first
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    public func read(_ path: String) async throws -> String {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let local = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        _ = try await transport.sftp(
            ["get \(Self.quote(path)) \(Self.quote(local.path))"], path: path)
        guard let data = try? Data(contentsOf: local) else {
            throw SSHError.protocolFailure(detail: "download of \(path) produced no file")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SSHError.protocolFailure(detail: "\(path) isn't UTF-8 text")
        }
        return text
    }

    /// File-oriented stat: `ls -la <file>` lists exactly that file. If sftp
    /// listed multiple entries instead, `path` was a directory.
    public func stat(_ path: String) async throws -> ResourceMeta {
        let out = try await transport.sftp(["ls -la \(Self.quote(path))"], path: path)
        let entries = SFTPListingParser.parse(out)
        let name = (path as NSString).lastPathComponent
        if entries.count == 1, let entry = entries.first,
           entry.name == name || entry.name == path || entry.name.hasSuffix("/\(name)") {
            return ResourceMeta(isDirectory: entry.isDirectory, size: entry.size, mode: entry.mode)
        }
        // Contents got listed (or empty dir): it's a directory.
        return ResourceMeta(isDirectory: true, size: nil, mode: nil)
    }

    /// Resolve a (possibly relative) remote path — used to turn the initial
    /// "." into the absolute home directory for breadcrumbs/recents.
    public func realpath(_ path: String) async throws -> String {
        let out = try await transport.sftp(["cd \(Self.quote(path))", "pwd"], path: path)
        guard let resolved = SFTPListingParser.workingDirectory(in: out) else {
            throw SSHError.protocolFailure(detail: "couldn't resolve remote path \(path)")
        }
        return resolved
    }

    public func write(_ text: String, to path: String) async throws {
        // Implemented in the next task (atomic temp + rename).
        throw SSHError.protocolFailure(detail: "write not implemented yet")
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/SSH/SSHFileSource.swift Tests/LumeKitTests/SSHFileSourceTests.swift
git commit -m "feat: SSHFileSource list/read/stat/realpath over sftp batches"
```

---

### Task 9: `SSHFileSource.write` — atomic, permission-preserving

**Files:**
- Modify: `Sources/LumeKit/SSH/SSHFileSource.swift` (replace the `write` stub)
- Test: `Tests/LumeKitTests/SSHFileSourceWriteTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

struct SSHFileSourceWriteTests {
    /// Source with a deterministic temp suffix so batch contents are assertable.
    private func makeSource(_ runner: FakeCommandRunner) -> SSHFileSource {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHWriteTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = SSHHost(alias: "web1")
        let transport = SSHTransport(host: host, runner: runner,
                                     controlDir: dir.appendingPathComponent("ctl"))
        return SSHFileSource(host: host, transport: transport, tempDir: dir,
                             tempSuffix: { "fixed" })
    }

    private let statLine = "-rw-r----- 1 root wheel 2049 Jun  9 10:00 /etc/app/config.yaml"

    @Test func writeStatsThenPutsChmodsRenames() async throws {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(statLine),   // stat batch
            FakeCommandRunner.ok(),           // put+chmod+rename batch
        ])
        try await makeSource(runner).write("new contents", to: "/etc/app/config.yaml")

        #expect(runner.calls.count == 2)
        let batch = runner.calls[1].stdin ?? ""
        let lines = batch.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("put \"") )
        #expect(lines[0].hasSuffix("\"/etc/app/config.yaml.lume-tmp-fixed\""))
        #expect(lines[1] == "chmod 640 \"/etc/app/config.yaml.lume-tmp-fixed\"")
        #expect(lines[2] == "rename \"/etc/app/config.yaml.lume-tmp-fixed\" \"/etc/app/config.yaml\"")
    }

    @Test func failedBatchCleansUpTempAndRethrows() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.ok(statLine),                                       // stat
            FakeCommandRunner.fail(#"remote open: Permission denied"#),           // put fails
            FakeCommandRunner.ok(),                                               // cleanup rm
        ])
        let source = makeSource(runner)
        await #expect(throws: SSHError.permissionDenied(path: "/etc/app/config.yaml")) {
            try await source.write("x", to: "/etc/app/config.yaml")
        }
        #expect(runner.calls.count == 3)
        #expect(runner.calls[2].stdin == "rm \"/etc/app/config.yaml.lume-tmp-fixed\"\n")
    }

    @Test func statFailurePropagatesWithoutWriting() async {
        let runner = FakeCommandRunner(results: [
            FakeCommandRunner.fail("Couldn't stat remote file: No such file or directory"),
        ])
        let source = makeSource(runner)
        await #expect(throws: SSHError.notFound(path: "/etc/app/config.yaml")) {
            try await source.write("x", to: "/etc/app/config.yaml")
        }
        #expect(runner.calls.count == 1)   // nothing was uploaded
    }
}
```

- [ ] **Step 2: Run to verify failure** — first test fails (`write not implemented yet` protocolFailure)

- [ ] **Step 3: Replace the `write` stub in `SSHFileSource.swift`**

```swift
    /// Atomic, permission-preserving save:
    ///   1. stat the original (mode capture — also fails fast if it vanished),
    ///   2. upload the buffer to `<path>.lume-tmp-<suffix>` in the same dir,
    ///   3. chmod the temp to the original's mode,
    ///   4. rename over the original (OpenSSH uses posix-rename → atomic).
    /// On any failure the temp is removed best-effort; the original is never
    /// touched until the rename, so readers can't observe a partial file.
    public func write(_ text: String, to path: String) async throws {
        let meta = try await stat(path)
        let mode = String(format: "%o", (meta.mode ?? 0o644) & 0o777)
        let remoteTemp = "\(path).lume-tmp-\(tempSuffix())"

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let local = tempDir.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        do {
            _ = try await transport.sftp([
                "put \(Self.quote(local.path)) \(Self.quote(remoteTemp))",
                "chmod \(mode) \(Self.quote(remoteTemp))",
                "rename \(Self.quote(remoteTemp)) \(Self.quote(path))",
            ], path: path)
        } catch {
            // Best-effort cleanup; `-b` aborted the batch at the failed step.
            _ = try? await transport.sftp(["rm \(Self.quote(remoteTemp))"])
            throw error
        }
    }
```

- [ ] **Step 4: Run tests** — Expected: PASS (3 tests). Run the full suite too.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/SSH/SSHFileSource.swift Tests/LumeKitTests/SSHFileSourceWriteTests.swift
git commit -m "feat: atomic permission-preserving remote save (put + chmod + rename)"
```

---

### Task 10: `ConnectionStore` (manual hosts + per-host recents, JSON-backed)

**Files:**
- Create: `Sources/LumeKit/SSH/ConnectionStore.swift`
- Test: `Tests/LumeKitTests/ConnectionStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import LumeKit

@MainActor
struct ConnectionStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStoreTests-\(UUID().uuidString).json")
    }

    @Test func manualHostsPersistAcrossReload() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        store.addManualHost(SSHHost(alias: "prod", hostname: "10.0.0.5", user: "deploy"))
        let reloaded = ConnectionStore(fileURL: url)
        #expect(reloaded.state.manualHosts.map(\.alias) == ["prod"])
        #expect(reloaded.state.manualHosts[0].user == "deploy")
    }

    @Test func addingSameAliasReplaces() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        store.addManualHost(SSHHost(alias: "prod", hostname: "old"))
        store.addManualHost(SSHHost(alias: "prod", hostname: "new"))
        #expect(store.state.manualHosts.count == 1)
        #expect(store.state.manualHosts[0].hostname == "new")
    }

    @Test func recentFilesAreMRUCappedAtEight() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        for i in 1...10 { store.noteOpened(alias: "web1", file: "/etc/f\(i)") }
        store.noteOpened(alias: "web1", file: "/etc/f3")   // re-open → moves to front
        let recents = store.state.hostState["web1"]?.recentFiles ?? []
        #expect(recents.count == 8)
        #expect(recents.first == "/etc/f3")
        #expect(!recents.contains("/etc/f1"))               // pushed out by the cap
    }

    @Test func lastPathAndRemoveHost() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)
        store.noteBrowsed(alias: "web1", path: "/srv/app")
        #expect(store.state.hostState["web1"]?.lastPath == "/srv/app")
        store.removeManualHost(alias: "web1")
        #expect(store.state.hostState["web1"] == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cannot find 'ConnectionStore' in scope`

- [ ] **Step 3: Write `Sources/LumeKit/SSH/ConnectionStore.swift`**

```swift
import Foundation
import Observation

/// Everything Lume remembers about SSH connections: manually-entered hosts
/// plus per-host last path / recent files. JSON in Application Support —
/// deliberately NOT the SwiftData library store (no relationships needed, and
/// the library schema has delicate migration constraints).
public struct ConnectionStoreState: Codable, Sendable, Equatable {
    public var manualHosts: [SSHHost] = []
    public var hostState: [String: HostState] = [:]   // keyed by alias

    public init() {}

    public struct HostState: Codable, Sendable, Equatable {
        public var lastPath: String?
        public var recentFiles: [String] = []
        public var lastUsed: Date?
        public init() {}
    }
}

@MainActor
@Observable
public final class ConnectionStore {
    public private(set) var state: ConnectionStoreState
    private let fileURL: URL
    private static let recentsCap = 8

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume/connections.json")
    }

    public init(fileURL: URL = ConnectionStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ConnectionStoreState.self, from: data) {
            state = decoded
        } else {
            state = ConnectionStoreState()
        }
    }

    public func addManualHost(_ host: SSHHost) {
        state.manualHosts.removeAll { $0.alias == host.alias }
        state.manualHosts.append(host)
        persist()
    }

    public func removeManualHost(alias: String) {
        state.manualHosts.removeAll { $0.alias == alias }
        state.hostState[alias] = nil
        persist()
    }

    public func noteConnected(alias: String) {
        state.hostState[alias, default: .init()].lastUsed = Date()
        persist()
    }

    public func noteBrowsed(alias: String, path: String) {
        state.hostState[alias, default: .init()].lastPath = path
        persist()
    }

    public func noteOpened(alias: String, file: String) {
        var hostState = state.hostState[alias, default: .init()]
        hostState.recentFiles.removeAll { $0 == file }
        hostState.recentFiles.insert(file, at: 0)
        if hostState.recentFiles.count > Self.recentsCap {
            hostState.recentFiles.removeLast(hostState.recentFiles.count - Self.recentsCap)
        }
        state.hostState[alias] = hostState
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

Note: decoding uses the default date strategy mismatch trap — add `decoder.dateDecodingStrategy = .iso8601` in `init`:

```swift
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = (try? decoder.decode(ConnectionStoreState.self, from: data)) ?? ConnectionStoreState()
        } else {
            state = ConnectionStoreState()
        }
```

- [ ] **Step 4: Run tests** — Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/LumeKit/SSH/ConnectionStore.swift Tests/LumeKitTests/ConnectionStoreTests.swift
git commit -m "feat: ConnectionStore — manual SSH hosts and per-host recents (JSON-backed)"
```

---

### Task 11: `RemoteSession` + AppState remote state and routing

App-target code (no LumeKitTests coverage — verified by build + the Task 15 manual checklist).

**Files:**
- Create: `Sources/Lume/Remote/RemoteSession.swift`
- Modify: `Sources/Lume/AppState.swift` (new MARK section + 3 small touch-ups)

- [ ] **Step 1: Write `Sources/Lume/Remote/RemoteSession.swift`**

```swift
import Foundation
import Observation
import LumeKit

/// One live SSH connection: its transport, file source, and the remote tree's
/// UI state (root, expansion, lazily-loaded children).
@MainActor
@Observable
final class RemoteSession {
    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let host: SSHHost
    let transport: SSHTransport
    let source: SSHFileSource

    var phase: Phase = .connecting
    /// The directory the tree is rooted at (resolved to absolute on connect).
    var rootPath: String
    /// Lazily-loaded children per directory path; missing key = not loaded yet.
    private(set) var children: [String: [ResourceNode]] = [:]
    var expanded: Set<String> = []
    /// In-flight loads (guards double-fetch from row `.task` + toggleExpand).
    private var loading: Set<String> = []
    /// Last non-fatal listing error (shown as a notice by the tree view).
    var lastError: String?

    init(host: SSHHost, startPath: String?) {
        self.host = host
        let transport = SSHTransport(host: host)
        self.transport = transport
        self.source = SSHFileSource(host: host, transport: transport)
        self.rootPath = startPath ?? "."
    }

    func connect() async {
        phase = .connecting
        do {
            try await transport.connect()
            if !rootPath.hasPrefix("/") {
                rootPath = try await source.realpath(rootPath)   // "." → home dir
            }
            phase = .ready
            await loadChildren(of: rootPath)
        } catch {
            phase = .failed((error as? SSHError)?.userMessage ?? error.localizedDescription)
        }
    }

    func loadChildren(of path: String) async {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            children[path] = try await source.list(path, includeHidden: false)
        } catch {
            children[path] = []
            lastError = (error as? SSHError)?.userMessage ?? error.localizedDescription
        }
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil {
                Task { await loadChildren(of: path) }
            }
        }
    }

    /// Re-root the tree (go-to-path on a directory).
    func reroot(to path: String) async {
        rootPath = path
        expanded.removeAll()
        children.removeAll()
        await loadChildren(of: path)
    }
}
```

- [ ] **Step 2: Add stored properties to `AppState`** — in `Sources/Lume/AppState.swift`, directly after the `// MARK: - Filters (sidebar)` block ends (before `// MARK: - Multi-selection (Finder-style)`), insert:

```swift
    // MARK: - Remote source (SSH)

    /// Live SSH session (nil when none). Kept while the user is back on Local
    /// so the connection survives the round-trip; cleared by Disconnect.
    var remote: RemoteSession?
    /// Whether the sidebar shows the remote tree (vs the local regions).
    private(set) var showingRemote = false
    /// The open remote file's absolute path; nil whenever a local file is open.
    private(set) var selectedRemotePath: String?
    /// True while a remote save is in flight (detail pane shows an indicator).
    private(set) var isRemoteSaving = false
    /// "New SSH Connection…" sheet visibility.
    var presentingNewConnection = false
    /// Host aliases parsed from ~/.ssh/config (loaded lazily, once).
    private(set) var sshConfigAliases: [String] = []
    /// Manual connections + per-host last path / recent files (JSON-backed).
    let connections = ConnectionStore()
```

- [ ] **Step 3: Add the remote methods** — append at the end of the `AppState` class body (after the existing `save()`), still inside the class:

```swift
    // MARK: - Remote source (SSH) — lifecycle

    /// Parse ~/.ssh/config (one level of Include) into the source-switcher list.
    func loadSSHConfigAliases() {
        guard sshConfigAliases.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        sshConfigAliases = SSHConfigParser.aliases(configText: text) { includePath in
            let expanded = NSString(string: includePath).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : home.appendingPathComponent(".ssh").appendingPathComponent(expanded)
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    func connectSSH(_ host: SSHHost) {
        // Reconnecting to the already-active host just brings its tree back.
        if let remote, remote.host.alias == host.alias {
            showRemoteSource()
            if case .failed = remote.phase { Task { await remote.connect() } }
            return
        }
        let previous = remote
        Task { await previous?.transport.disconnect() }
        let session = RemoteSession(
            host: host,
            startPath: connections.state.hostState[host.alias]?.lastPath)
        remote = session
        showingRemote = true
        clearDocumentSelection()
        connections.noteConnected(alias: host.alias)
        Task { await session.connect() }
    }

    func showLocalSource() {
        guard showingRemote else { return }
        showingRemote = false
        clearDocumentSelection()
    }

    func showRemoteSource() {
        guard remote != nil, !showingRemote else { return }
        showingRemote = true
        clearDocumentSelection()
    }

    func disconnectRemote() {
        let session = remote
        remote = nil
        showingRemote = false
        clearDocumentSelection()
        Task { await session?.transport.disconnect() }
    }

    /// Reset the open-document state when crossing the local/remote boundary.
    private func clearDocumentSelection() {
        loadTask?.cancel()
        selectedURL = nil
        selectedRemotePath = nil
        documentText = nil
        loadedText = nil
        isDirty = false
        errorMessage = nil
    }

    // MARK: - Remote source (SSH) — open / save

    /// Open a remote file from the tree or recents (remote `choose`).
    func chooseRemote(_ path: String) {
        if activeBundle != nil { closeBundle() }
        if activeScan != nil { closeScan() }
        selectedURL = nil
        selectedRemotePath = path
        loadTask?.cancel()
        loadTask = Task { await selectRemote(path) }
    }

    /// Remote sibling of `select(_:)` — same generation guard so a stale load
    /// can't land in a newer selection's buffer.
    func selectRemote(_ path: String) async {
        guard let remote else { return }
        let token = selectionGeneration.advance()
        selectedRemotePath = path
        errorMessage = nil
        let name = (path as NSString).lastPathComponent
        let kind = FileKind.detect(filename: name)
        selectedKind = kind
        let isConfig = ConfigRegistry.format(forFilename: name) != nil
        guard Self.textEditableKinds.contains(kind) || isConfig else {
            documentText = nil
            loadedText = nil
            isDirty = false
            return
        }
        do {
            let text = try await remote.source.read(path)
            guard selectionGeneration.isCurrent(token), selectedRemotePath == path else { return }
            documentText = text
            loadedText = text
            isDirty = false
            connections.noteOpened(alias: remote.host.alias, file: path)
        } catch {
            guard selectionGeneration.isCurrent(token), selectedRemotePath == path else { return }
            documentText = nil
            loadedText = nil
            errorMessage = (error as? SSHError)?.userMessage
                ?? "Couldn't open \(name) over SSH."
        }
    }

    /// Go-to-path: directory → re-root the tree; file → open it.
    func goToRemotePath(_ raw: String) {
        guard let remote else { return }
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else {
            showNotice("Enter an absolute remote path (starting with /).")
            return
        }
        Task {
            do {
                let meta = try await remote.source.stat(path)
                if meta.isDirectory {
                    await remote.reroot(to: path)
                    connections.noteBrowsed(alias: remote.host.alias, path: path)
                } else {
                    chooseRemote(path)
                }
            } catch {
                showNotice((error as? SSHError)?.userMessage ?? "Couldn't open \(path).")
            }
        }
    }

    /// Remote save: async atomic write; on failure the buffer stays dirty so
    /// nothing is lost. Mirrors `save()`'s in-flight-typing handling.
    private func saveRemote(_ path: String) {
        guard let remote, let text = documentText, isDirty, !isRemoteSaving else { return }
        isRemoteSaving = true
        Task {
            do {
                try await remote.source.write(text, to: path)
                if selectedRemotePath == path {
                    loadedText = text
                    isDirty = (documentText != text)
                }
            } catch {
                showNotice((error as? SSHError)?.userMessage
                    ?? "Couldn't save \((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
            isRemoteSaving = false
        }
    }
```

- [ ] **Step 4: Route ⌘S and local selection across the boundary** — three small edits in `AppState.swift`:

1. Top of `save()` (line ~1382), add the remote branch first:

```swift
    func save() {
        if let remotePath = selectedRemotePath { saveRemote(remotePath); return }
        guard let url = selectedURL, let text = documentText, isDirty else { return }
        ...
```

2. In `choose(_ url: URL)` (line ~1331), clear the remote selection so a local pick replaces a remote document:

```swift
    func choose(_ url: URL) {
        if activeBundle != nil { closeBundle() }
        if activeScan != nil { closeScan() }
        selectedRemotePath = nil
        selectedURL = url
        ...
```

3. In `openFolder(_ url: URL)` (line ~284), add `selectedRemotePath = nil` next to the existing `selectedURL = nil`.

- [ ] **Step 5: Build** (no new tests — app target):

```bash
xcodegen generate
xcodebuild -project Lume.xcodeproj -scheme Lume -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. Also run the full LumeKitTests suite — still green.

- [ ] **Step 6: Commit**

```bash
git add Sources/Lume/Remote/RemoteSession.swift Sources/Lume/AppState.swift project.yml Lume.xcodeproj
git commit -m "feat: RemoteSession + AppState remote selection, go-to-path, and save routing"
```

---

### Task 12: Source switcher UI

**Files:**
- Create: `Sources/Lume/Remote/SourceSwitcherView.swift`
- Modify: `Sources/Lume/SidebarView.swift` (mount the header + the sheet)

- [ ] **Step 1: Write `Sources/Lume/Remote/SourceSwitcherView.swift`**

```swift
import SwiftUI
import LumeKit

/// Compact header above the sidebar tree: shows the active source and switches
/// between Local, ~/.ssh/config hosts, saved manual connections, and new ones.
struct SourceSwitcherView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    app.showLocalSource()
                } label: {
                    Label(localTitle, systemImage: "internaldrive")
                }
                if let remote = app.remote, !app.showingRemote {
                    Button {
                        app.showRemoteSource()
                    } label: {
                        Label(remote.host.alias, systemImage: "bolt.horizontal")
                    }
                }
                if !app.sshConfigAliases.isEmpty {
                    Section("~/.ssh/config") {
                        ForEach(app.sshConfigAliases, id: \.self) { alias in
                            Button(alias) { app.connectSSH(SSHHost(alias: alias)) }
                        }
                    }
                }
                if !app.connections.state.manualHosts.isEmpty {
                    Section("Saved Connections") {
                        ForEach(app.connections.state.manualHosts) { host in
                            Button(host.alias) { app.connectSSH(host) }
                        }
                    }
                }
                Divider()
                Button("New SSH Connection…") { app.presentingNewConnection = true }
                if app.remote != nil {
                    Button("Disconnect", role: .destructive) { app.disconnectRemote() }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.showingRemote ? "bolt.horizontal.circle.fill" : "internaldrive")
                        .foregroundStyle(app.showingRemote ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear { app.loadSSHConfigAliases() }

            Spacer(minLength: 4)
            statusAccessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var localTitle: String {
        if let root = app.rootURL { return "Local — \(root.lastPathComponent)" }
        return "Local"
    }

    private var title: String {
        if app.showingRemote, let remote = app.remote { return remote.host.alias }
        return localTitle
    }

    @ViewBuilder private var statusAccessory: some View {
        if app.showingRemote, let remote = app.remote {
            switch remote.phase {
            case .connecting:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Connection failed")
            case .ready:
                EmptyView()
            }
        }
    }
}
```

- [ ] **Step 2: Mount it in `SidebarView.swift`** — replace the start of `body`'s `VStack` so the header is always visible and the remote tree swaps in:

```swift
    var body: some View {
        VStack(spacing: 0) {
            SourceSwitcherView()
            Divider()
            if app.showingRemote, app.remote != nil {
                RemoteTreeView()
            } else if app.rootURL != nil || !app.scans.isEmpty {
                List {
                    ScansRegion()
                    ...existing unchanged...
```

(The existing `List`/`SelectionActionBar`/`SidebarFilterBar`/`emptyState` content is unchanged — only nested one level deeper under the new `if`.) Add the sheet alongside the existing ones:

```swift
        .sheet(isPresented: bindableApp.presentingNewConnection) { NewConnectionSheet() }
```

`RemoteTreeView` and `NewConnectionSheet` arrive in Tasks 13–14; to keep this task building, add temporary placeholders at the bottom of `SourceSwitcherView.swift` **and delete them in Tasks 13/14**:

```swift
// TEMPORARY placeholders — replaced by Tasks 13 and 14.
struct RemoteTreeView: View {
    var body: some View { ContentUnavailableView("Remote", systemImage: "bolt.horizontal") }
}
struct NewConnectionSheet: View {
    var body: some View { Text("New Connection").padding() }
}
```

- [ ] **Step 3: Build** — Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Smoke-run** (optional but recommended): `open build/Build/Products/Debug/Lume.app` — header shows `Local — <folder>`, menu lists your `~/.ssh/config` hosts.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lume/Remote/SourceSwitcherView.swift Sources/Lume/SidebarView.swift
git commit -m "feat: sidebar source switcher (Local / SSH hosts / new connection)"
```

---

### Task 13: `RemoteTreeView` — lazy tree, go-to-path, recents

**Files:**
- Create: `Sources/Lume/Remote/RemoteTreeView.swift`
- Modify: `Sources/Lume/Remote/SourceSwitcherView.swift` (delete the `RemoteTreeView` placeholder)

- [ ] **Step 1: Delete the temporary `RemoteTreeView` placeholder** from `SourceSwitcherView.swift`.

- [ ] **Step 2: Write `Sources/Lume/Remote/RemoteTreeView.swift`**

```swift
import SwiftUI
import LumeKit

/// The sidebar when an SSH source is active: connection states, a go-to-path
/// field, per-host recent files, and a lazily-expanding remote tree.
struct RemoteTreeView: View {
    @Environment(AppState.self) private var app
    @State private var pathField = ""

    var body: some View {
        if let remote = app.remote {
            VStack(spacing: 0) {
                switch remote.phase {
                case .connecting:
                    Spacer()
                    ProgressView("Connecting to \(remote.host.alias)…")
                        .controlSize(.small)
                    Spacer()
                case .failed(let message):
                    Spacer()
                    ContentUnavailableView {
                        Label("Can't Connect", systemImage: "bolt.horizontal")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await remote.connect() } }
                            .buttonStyle(.borderedProminent)
                        Button("Disconnect") { app.disconnectRemote() }
                    }
                    Spacer()
                case .ready:
                    goToBar
                    Divider()
                    List {
                        if !recentFiles.isEmpty {
                            Section("Recent") {
                                ForEach(recentFiles, id: \.self) { path in
                                    Button {
                                        app.chooseRemote(path)
                                    } label: {
                                        Label {
                                            Text((path as NSString).lastPathComponent)
                                                .lineLimit(1)
                                        } icon: {
                                            Image(systemName: "clock")
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help(path)
                                }
                            }
                        }
                        Section(remote.rootPath) {
                            RemoteChildrenRows(directory: remote.rootPath, depth: 0)
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: remote.lastError) { _, error in
                        if let error {
                            app.showNotice(error)
                            remote.lastError = nil
                        }
                    }
                }
            }
        }
    }

    private var recentFiles: [String] {
        guard let alias = app.remote?.host.alias else { return [] }
        return app.connections.state.hostState[alias]?.recentFiles ?? []
    }

    private var goToBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.secondary)
            TextField("Go to path (/etc/nginx/nginx.conf)", text: $pathField)
                .textFieldStyle(.plain)
                .onSubmit {
                    app.goToRemotePath(pathField)
                    pathField = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One directory's rows; shows an inline spinner the first time a directory
/// is expanded (children load lazily, exactly like the local tree).
private struct RemoteChildrenRows: View {
    @Environment(AppState.self) private var app
    let directory: String
    let depth: Int

    var body: some View {
        if let remote = app.remote {
            if let nodes = remote.children[directory] {
                ForEach(nodes) { node in
                    RemoteNodeRow(node: node, depth: depth)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(depth) * 14)
                .task { await remote.loadChildren(of: directory) }
            }
        }
    }
}

private struct RemoteNodeRow: View {
    @Environment(AppState.self) private var app
    let node: ResourceNode
    let depth: Int

    var body: some View {
        if let remote = app.remote {
            if node.isDirectory {
                Button {
                    remote.toggleExpand(node.ref.path)
                } label: {
                    row(systemImage: "folder",
                        chevron: remote.expanded.contains(node.ref.path) ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                if remote.expanded.contains(node.ref.path) {
                    RemoteChildrenRows(directory: node.ref.path, depth: depth + 1)
                }
            } else {
                Button {
                    app.chooseRemote(node.ref.path)
                } label: {
                    row(systemImage: "doc", chevron: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var isSelected: Bool { app.selectedRemotePath == node.ref.path }

    private func row(systemImage: String, chevron: String?) -> some View {
        HStack(spacing: 5) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text(node.name)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: Build** — Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/Remote/
git commit -m "feat: remote sidebar tree with go-to-path and per-host recents"
```

---

### Task 14: `NewConnectionSheet`

**Files:**
- Create: `Sources/Lume/Remote/NewConnectionSheet.swift`
- Modify: `Sources/Lume/Remote/SourceSwitcherView.swift` (delete the `NewConnectionSheet` placeholder)

- [ ] **Step 1: Delete the temporary `NewConnectionSheet` placeholder** from `SourceSwitcherView.swift`.

- [ ] **Step 2: Write `Sources/Lume/Remote/NewConnectionSheet.swift`**

```swift
import SwiftUI
import LumeKit

/// Manual connection entry for hosts not in ~/.ssh/config. Saved to the
/// ConnectionStore, then connected immediately.
struct NewConnectionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var hostname = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var alias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New SSH Connection")
                .font(.headline)
            Form {
                TextField("Host", text: $hostname, prompt: Text("server.example.com"))
                TextField("User", text: $user, prompt: Text("optional — defaults to your ssh config"))
                TextField("Port", text: $port, prompt: Text("22"))
                TextField("Identity file", text: $identityFile, prompt: Text("~/.ssh/id_ed25519 (optional)"))
                TextField("Name", text: $alias, prompt: Text("defaults to the host"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func connect() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let name = alias.trimmingCharacters(in: .whitespaces)
        let host = SSHHost(
            alias: name.isEmpty ? trimmedHost : name,
            hostname: trimmedHost,
            user: user.isEmpty ? nil : user.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)),
            identityFile: identityFile.isEmpty ? nil
                : NSString(string: identityFile.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        )
        app.connections.addManualHost(host)
        app.connectSSH(host)
        dismiss()
    }
}
```

- [ ] **Step 3: Build** — Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sources/Lume/Remote/
git commit -m "feat: manual New SSH Connection sheet"
```

---

### Task 15: Detail-pane remote routing, save indicator, manual checklist, README

**Files:**
- Modify: `Sources/Lume/ContentView.swift` (`DetailView`)
- Create: `docs/ssh-manual-test-checklist.md`
- Modify: `README.md` (roadmap line)

- [ ] **Step 1: Route remote selections in `DetailView`** (`Sources/Lume/ContentView.swift:127`). Add the remote branch BEFORE the `selectedURL` branch:

```swift
        } else if let message = app.errorMessage {
            ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if let remotePath = app.selectedRemotePath {
            remoteViewer(forPath: remotePath)
        } else if let url = app.selectedURL {
```

And add the helper below the existing `viewer(for:)`:

```swift
    /// Remote files reuse the text-backed editors (they render `documentText`,
    /// which `selectRemote` filled). URL-backed viewers (PDF/image/HTML/
    /// QuickLook) need a local file — out of scope for the SSH MVP.
    @ViewBuilder
    private func remoteViewer(forPath path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        Group {
            switch DocumentRouter.viewer(forFilename: name) {
            case .envEditor:
                EnvEditorView()
            case .configEditor:
                ConfigEditorView()
            case .markdownEditor, .codeViewer:
                if app.documentText != nil { EditorView() } else { loading }
            case .pdf, .image, .html, .quickLook:
                ContentUnavailableView(
                    "Text Only Over SSH",
                    systemImage: "bolt.horizontal",
                    description: Text("\(name) can't be previewed over SSH — only text and config files open remotely.")
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if app.isRemoteSaving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
            }
        }
    }
```

Note: `DocumentTagBar` is local-only — the remote branch deliberately skips it (tags are a disabled affordance while remote, per the spec).

- [ ] **Step 2: Build + full test suite** — Expected: `BUILD SUCCEEDED`, all LumeKitTests PASS.

- [ ] **Step 3: Write `docs/ssh-manual-test-checklist.md`**

```markdown
# SSH backend — manual integration checklist

Run against localhost (`System Settings → Sharing → Remote Login`, or any
reachable host in ~/.ssh/config). Re-run before tagging a release that touches
the SSH layer.

Setup: `ssh localhost true` works from a terminal without a password prompt
(key in agent) — or expect the native askpass dialog at step 2.

1. [ ] Source menu lists hosts from ~/.ssh/config and "New SSH Connection…".
2. [ ] Connect to localhost → spinner, then tree shows the home directory.
   (If the key needs a passphrase: native Lume — SSH dialog appears; Cancel
   surfaces "Can't Connect" with Retry.)
3. [ ] Expand a few directories — lazy loading, folders first, dotfiles hidden,
   `.env` visible, `node_modules`/`.git` absent.
4. [ ] Go-to-path with a directory (e.g. `/tmp`) re-roots the tree; with a file
   (e.g. `/etc/hosts`) opens it read-only-ish (it's text → editor shows).
5. [ ] Open a writable text file (`~/lume-ssh-test.md`; create it first:
   `echo hi > ~/lume-ssh-test.md`), edit, ⌘S → "Saving…" flashes; verify with
   `cat ~/lume-ssh-test.md` and `ls -l` (same permissions as before).
6. [ ] Set restrictive perms: `chmod 400 ~/lume-ssh-test.md`, edit, ⌘S →
   notice "The remote user can't write …"; buffer stays dirty; `chmod 644`,
   ⌘S again → saves. No `.lume-tmp-*` litter in the directory.
7. [ ] Open a `.yaml`/`.env` file remotely → structured/env editor renders;
   edits save through ⌘S.
8. [ ] Open a binary (e.g. an image) remotely → "Text Only Over SSH" pane.
9. [ ] Recent files section shows the opened files (MRU, this host only).
10. [ ] Switch to Local mid-session → local tree intact; switch back → remote
    tree + connection still alive (no reconnect spinner).
11. [ ] Kill the master: `pkill -f 'ssh.*ControlMaster'`, then click a folder →
    one transparent reconnect (or askpass), listing succeeds.
12. [ ] Disconnect → back to Local; control socket gone from
    `~/Library/Application Support/Lume/ssh/`.
13. [ ] Quit + relaunch → saved manual connection still listed; per-host
    recents and last path survive.
14. [ ] Connect to an unreachable host (manual entry `10.255.255.1`) → clear
    "Can't Connect" with Retry/Disconnect within ~15 s (ConnectTimeout).
```

- [ ] **Step 4: Update `README.md`** — in the Roadmap list, add after the file-management line:

```markdown
- **SSH remote editing** *(shipped)* — connect to a host from the sidebar source
  switcher, browse, and atomically edit remote text/config files
```

- [ ] **Step 5: Run the manual checklist against localhost.** Fix what fails before closing the task.

- [ ] **Step 6: Commit**

```bash
git add Sources/Lume/ContentView.swift docs/ssh-manual-test-checklist.md README.md
git commit -m "feat: remote detail-pane routing, save indicator, manual SSH checklist"
```

---

## Plan completion criteria

- All LumeKitTests pass (`xcodebuild test … 2>&1 | tail -20` shows TEST SUCCEEDED).
- Manual checklist (Task 15) fully checked against localhost sshd.
- Local behavior unchanged: open folder, browse, favorites, tags, scans, ⌘S all work exactly as before (parity tests + smoke run).
- Spec non-goals respected: no sudo-edit, no remote favorites/tags/file-ops/watching, one active source at a time.
