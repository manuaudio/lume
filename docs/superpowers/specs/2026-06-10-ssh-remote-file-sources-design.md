# Remote File Sources + SSH Backend (MVP) — Design

**Date:** 2026-06-10
**Status:** Approved for planning
**Sub-project:** 1 of 3 (SSH → GitHub → remote favorites sync). This spec also
delivers the shared foundation (sub-project 0), folded in so the abstraction is
designed against a real consumer.

## Goal

Let the user connect to a remote system over SSH, browse its files, and make
quick, safe edits to known files (configs, `.env`, YAML, nginx.conf, …) using
Lume's existing editors — without changing how the local experience behaves.

**Primary workflow:** quick targeted config edits. Not a full remote-dev
workspace (that may grow later; the abstraction allows it, the MVP doesn't
build it).

## Decisions (settled during brainstorming)

| Question | Decision |
|---|---|
| Scope split | Foundation (`FileSource`) folded into the SSH spec; GitHub and favorites-sync are separate later specs |
| Transport | Shell out to system `ssh`/`sftp` binaries (no SwiftPM SSH dependency) |
| Connections | Both: parse `~/.ssh/config` hosts **and** a manual New Connection form |
| Navigation | Both: lazy browse tree from a root **and** go-to-path + per-host recents |
| Save semantics | Atomic (temp + rename in same dir), preserve existing file mode |
| Root-owned files | Out of scope — clear permission-denied error; no sudo-edit in MVP |
| Window model | Source switcher in the sidebar; one window, tree swaps in place |
| Adoption strategy | Approach C: real `FileSource` abstraction, incrementally adopted (active tree + editor only) |

**Known tension (accepted):** shelling out to `ssh` is incompatible with the
App Sandbox, which is on the roadmap. If/when Lume sandboxes, the transport
layer is the contained swap point (e.g. to Citadel/swift-nio-ssh); everything
above `SSHFileSource`'s public surface is transport-agnostic.

## Architecture

### 1. Foundation — `FileSource` (LumeKit, UI-free)

New directory `Sources/LumeKit/Sources/`:

```swift
public enum SourceID: Hashable, Sendable {
    case local
    case ssh(alias: String)   // alias = host nickname (config Host or manual name)
}

/// Identifies a resource within some source — replaces "everything is a local URL".
public struct ResourceRef: Hashable, Sendable {
    public let sourceID: SourceID
    public let path: String          // absolute path within the source
}

public struct ResourceMeta: Sendable {
    public let isDirectory: Bool
    public let size: Int64?
    public let mode: UInt16?         // POSIX permissions when known
    public let writableHint: Bool?   // best-effort "can we likely save this"
}

/// A node in a source's tree. FileNode generalized: children == nil means
/// "not a directory or not yet expanded" (same lazy contract as FileNode).
public struct ResourceNode: Identifiable, Equatable, Sendable {
    public let ref: ResourceRef
    public let isDirectory: Bool
    public var children: [ResourceNode]?
    public var id: ResourceRef { ref }
    public var name: String          // last path component
}

public protocol FileSource: Sendable {
    var id: SourceID { get }
    func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode]
    func read(_ path: String) async throws -> String
    func write(_ text: String, to path: String) async throws
    func stat(_ path: String) async throws -> ResourceMeta
}
```

- **`LocalFileSource`** wraps the existing `FileService` enumeration rules
  (ignored names, dotfile policy, folders-first sort) and the existing
  `TextDocument` load/save logic (`NSFileCoordinator`-coordinated, atomic,
  iCloud download kick). Local behavior is byte-for-byte unchanged.
- **Adoption boundary (Approach C):** only the *active browse tree* and the
  *editor load/save path* route through `FileSource`. These stay URL-based and
  local-only in this sub-project: favorites/library, tags, scans, file-ops
  (create/rename/move/delete), `DirectoryWatcher`, selection internals,
  `FileNode`. Later sub-projects migrate them.

### 2. SSH backend — `SSHFileSource` (LumeKit)

Speaks to the system's `ssh`/`sftp` via `Process`. All subprocess use is behind
a `CommandRunning` protocol so the logic is unit-testable with fakes.

- **Connection lifecycle:** `ssh` `ControlMaster` with a Lume-owned control
  socket under `~/Library/Application Support/Lume/ssh/`. First operation
  establishes the master (auth happens once); subsequent operations multiplex.
  `ControlPersist` keeps it warm between operations. The user's
  `~/.ssh/config`, keys, agent, and `known_hosts` apply exactly as in a
  terminal.
- **Interactive auth:** if a host needs a passphrase/password, `SSH_ASKPASS`
  (+ `SSH_ASKPASS_REQUIRE=force`) points at a small Lume helper that shows a
  native prompt. Nothing is stored by Lume.
- **List:** one persistent `sftp -q` process per connection fed batch commands
  over stdin; `ls -la <path>` output parsed into `ResourceNode`s (mode, size,
  dir-bit from the listing). Filtering/sorting reuses the same rules as local
  (ignored names, dotfile policy, folders-first).
- **Read:** `get <remote> <local-temp>` into Lume's cache dir, then read UTF-8.
  Temp files cleaned on close/quit.
- **Write (atomic + preserve perms):**
  1. `stat` original; capture mode.
  2. `put` buffer to `<path>.lume-tmp-<rand>` in the same directory.
  3. `chmod` temp to the original's mode.
  4. `rename` (sftp posix-rename) temp over original — readers never see a
     partial file.
  5. On any failure: delete temp, surface error, original untouched, editor
     buffer stays dirty.
- **Timeouts:** per-operation deadline (~30 s); `ConnectTimeout` on `ssh`.

### 3. Connections

- **`SSHConfigParser`** (LumeKit, pure, unit-tested): extracts `Host` stanzas
  from `~/.ssh/config` (and `Include`d files), skipping wildcard/negated
  patterns. Produces `[alias]` for the pick list — resolution of
  user/port/identity is left entirely to `ssh` itself.
- **Manual connections:** "New SSH Connection…" sheet (host, user, port,
  optional identity file). Persisted as a new SwiftData model in the existing
  library store. Manual fields are passed as `ssh -p/-i/-l` flags.
- **`ConnectionStore`:** unifies both kinds; tracks per-host last browse path,
  recent files, and last-used ordering.

### 4. UI

- **Source switcher:** compact header above the sidebar tree showing the
  current source (`Local — ~/Developer/lume` or `⚡ prod-web1`) with a menu:
  Local, configured hosts (from `~/.ssh/config`), saved manual connections,
  recent hosts, "New SSH Connection…".
- **Connecting:** inline spinner in the header; on success land at the
  per-host last path (else remote home `.`); on failure show error + retry in
  the header. Local tree state is preserved and restored when switching back.
- **Remote tree:** same lazy expand UX as local, backed by
  `SSHFileSource.list`. A **go-to-path** field at the top jumps directly to a
  pasted absolute path (file → open it; directory → browse it). Per-host
  recent files listed under the field.
- **Editing:** remote file opens through `DocumentRouter` as today — Markdown
  highlighting, structured config editors, and the `.env` editor all work on
  remote content. ⌘S triggers the async atomic save with a saving indicator;
  failures land in the existing `errorMessage` surface and keep the buffer
  dirty.
- **Disabled while remote:** favorites/pinning, tags, scans, file-ops, watcher
  — hidden or disabled with no dead-end UI.

### 5. Error handling

Typed `SSHError` enum mapped to human messages:

| Failure | Behavior |
|---|---|
| Host unreachable / DNS / timeout | Header error + Retry; tree unchanged |
| Auth failed | Specific message ("authentication failed for `host`") |
| Permission denied on write | "The remote user can't write `path`." Buffer stays dirty. (Sudo-edit is a documented non-goal.) |
| Connection drop mid-session | Next op reconnects transparently (one retry); else header shows "Connection lost — Reconnect" |
| Connection drop mid-save | Temp-file protocol guarantees original intact; buffer stays dirty; error shown |
| Non-UTF-8 / binary remote file | Same "unsupported" pane as local |

### 6. Testing

- **Unit (LumeKit, no network):** `SSHConfigParser`; sftp `ls -la` parsing;
  atomic-write command sequencing and failure cleanup (via `CommandRunning`
  fake); `SSHError` mapping; `ConnectionStore` persistence.
- **Parity:** `LocalFileSource` tests asserting identical enumeration and
  load/save behavior to current `FileService`/`TextDocument`.
- **Integration (manual):** documented checklist against a local sshd
  (connect, browse, go-to-path, edit+save, perms preserved, permission-denied,
  kill-connection-mid-save).

## Non-goals (MVP)

- Sudo / root-owned file editing
- Full remote workspace features: favorites, tags, scans, file-ops, watching on remote
- Sandbox-compatible transport (documented swap point only)
- Multiple simultaneous remote sources visible at once (one active source at a time)
- GitHub backend, remote favorites sync (separate specs, build on `FileSource`)

## Build order (for the implementation plan)

1. `FileSource` protocol + `ResourceRef`/`ResourceNode`/`ResourceMeta`; `LocalFileSource` + parity tests.
2. Route active tree + editor load/save through the abstraction (local only — no visible change).
3. `CommandRunning` + ssh ControlMaster lifecycle + `SSHConfigParser`.
4. `SSHFileSource` list/read/stat; then atomic write.
5. ConnectionStore + New Connection sheet.
6. Source switcher UI + remote tree + go-to-path + recents.
7. Error surfaces, disabled-affordance polish, manual integration checklist.
