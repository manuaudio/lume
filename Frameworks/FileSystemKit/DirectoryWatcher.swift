import Foundation
import CoreServices

/// Watches a directory subtree for filesystem changes via FSEvents and delivers
/// the set of changed directory paths to a `@MainActor` closure. Used to keep
/// the cached file tree in sync with external edits (Finder, other apps) without
/// polling.
///
/// Concurrency: FSEvents calls back on a private serial dispatch queue. The C
/// trampoline receives an `Unmanaged<DirectoryWatcher>` (no non-Sendable Swift
/// state captured), reads the event paths, then hops to the main actor to invoke
/// `onChange`. The stream is created paused and started explicitly.
public final class DirectoryWatcher {
    private let onChange: @MainActor (Set<String>) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.lume.DirectoryWatcher", qos: .utility)

    /// Start watching `root` (recursively). `onChange` receives the set of
    /// changed directory paths on the main actor.
    public init(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
        self.onChange = onChange
        start(root: root)
    }

    deinit {
        // `stop()` is safe to call off the main actor: it only touches the
        // FSEvents stream handle, which is bound to this instance.
        teardown()
    }

    private func start(root: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a
            // CFArray of CFString.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var dirs: Set<String> = []
            for i in 0..<count {
                if let cfPath = CFArrayGetValueAtIndex(cfArray, i) {
                    let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
                    // File-level events report the file path; the tree caches by
                    // DIRECTORY, so collapse to the containing directory.
                    dirs.insert((path as NSString).deletingLastPathComponent)
                    dirs.insert(path)
                }
            }
            watcher.deliver(dirs)
        }

        let pathsToWatch = [root.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, // latency (seconds): coalesce bursts
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Hop the changed-path set to the main actor and invoke `onChange`.
    private func deliver(_ dirs: Set<String>) {
        guard !dirs.isEmpty else { return }
        let handler = onChange
        Task { @MainActor in handler(dirs) }
    }

    /// Stop watching and release the FSEvents stream. Idempotent.
    public func stop() {
        teardown()
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
