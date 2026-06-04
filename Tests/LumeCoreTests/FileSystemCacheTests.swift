import Testing
import Foundation
@testable import LumeCore

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
    func read(_ url: URL) throws -> String { try FileService().read(url) }
    func write(_ text: String, to url: URL) throws { try FileService().write(text, to: url) }
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
