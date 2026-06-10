import Testing
import Foundation
@testable import LumeKit

/// Counting spy: records how many times `enumerate` is called so tests can prove
/// the cache hits memory (one disk read) instead of re-enumerating per render.
private final class CountingFileService: FileServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var enumerateCount: Int { lock.withLock { _count } }

    func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode] {
        lock.withLock { _count += 1 }
        return try FileService().enumerate(directory, includeHidden: includeHidden)
    }
}

private func makeTempDirWithFile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumeCacheTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "x".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    return dir
}

@MainActor
@Test func cacheReturnsCachedArrayWithoutReEnumerating() throws {
    let dir = try makeTempDirWithFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spy = CountingFileService()
    let cache = FileSystemCache(files: spy)

    let first = cache.children(of: dir, includeHidden: false)
    let second = cache.children(of: dir, includeHidden: false)

    #expect(first == second)
    #expect(first.map(\.name) == ["a.md"])
    // Enumerated exactly ONCE despite two reads — second is a memory hit.
    #expect(spy.enumerateCount == 1)
}

@MainActor
@Test func invalidateReEnumeratesAndBumpsRevision() throws {
    let dir = try makeTempDirWithFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spy = CountingFileService()
    let cache = FileSystemCache(files: spy)

    _ = cache.children(of: dir, includeHidden: false)
    #expect(spy.enumerateCount == 1)
    let revBefore = cache.revision

    cache.invalidate(path: dir.path)
    #expect(cache.revision == revBefore + 1)

    _ = cache.children(of: dir, includeHidden: false)
    // After invalidation the next read goes back to disk.
    #expect(spy.enumerateCount == 2)
}

@MainActor
@Test func invalidateAllClearsAndBumps() throws {
    let dir = try makeTempDirWithFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spy = CountingFileService()
    let cache = FileSystemCache(files: spy)

    _ = cache.children(of: dir, includeHidden: false)
    _ = cache.children(of: dir, includeHidden: true)
    #expect(spy.enumerateCount == 2) // hidden + non-hidden are separate keys
    let revBefore = cache.revision

    cache.invalidateAll()
    #expect(cache.revision == revBefore + 1)

    _ = cache.children(of: dir, includeHidden: false)
    #expect(spy.enumerateCount == 3)
}

@MainActor
@Test func watcherInitAndStopSmoke() throws {
    let dir = try makeTempDirWithFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Live FSEvents timing isn't asserted; this just proves create/stop is safe.
    let watcher = DirectoryWatcher(root: dir) { _ in }
    watcher.stop()
    watcher.stop() // idempotent
}

/// Collects watcher deliveries on the main actor.
@MainActor
private final class ChangeCollector {
    var paths: Set<String> = []
}

@MainActor
@Test func watcherDeliversChangeForFileWrite() async throws {
    let dir = try makeTempDirWithFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = ChangeCollector()
    let watcher = DirectoryWatcher(root: dir) { collector.paths.formUnion($0) }
    defer { watcher.stop() }

    // Give FSEvents a beat to arm, then write; stream latency is 0.25s, so poll.
    try await Task.sleep(for: .milliseconds(300))
    try "y".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    for _ in 0..<100 where collector.paths.isEmpty {
        try await Task.sleep(for: .milliseconds(100))
    }
    // FSEvents reports /private-prefixed temp paths; compare by suffix.
    #expect(collector.paths.contains { $0.hasSuffix(dir.lastPathComponent) })
}

@MainActor
@Test func droppingWatcherWithEventsInFlightDoesNotCrash() async throws {
    // Regression for the teardown use-after-free window: generate events and
    // immediately stop + drop the last reference, exactly like
    // AppState.startWatching does when switching roots. Under the old
    // passUnretained context this could resurrect a deallocated watcher.
    for _ in 0..<20 {
        let dir = try makeTempDirWithFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        var watcher: DirectoryWatcher? = DirectoryWatcher(root: dir) { _ in }
        for i in 0..<5 {
            try "x".write(to: dir.appendingPathComponent("f\(i).md"),
                          atomically: true, encoding: .utf8)
        }
        watcher?.stop()
        watcher = nil
    }
    // Let any retained sinks and queued releases settle; passes by not crashing.
    try await Task.sleep(for: .milliseconds(500))
}
