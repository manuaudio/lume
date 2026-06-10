import Foundation
import CoreServices

/// Watches a directory subtree for filesystem changes via FSEvents and delivers
/// the set of changed directory paths to a `@MainActor` closure. Used to keep
/// the cached file tree in sync with external edits (Finder, other apps) without
/// polling.
///
/// Concurrency & lifetime: FSEvents calls back on a private serial dispatch
/// queue. The stream's context `info` is an `EventSink` that FSEvents itself
/// retains (the context supplies retain/release callbacks), so the callback
/// target stays alive until the stream is fully invalidated — an in-flight
/// event can never observe a deallocated object, even when the last
/// `DirectoryWatcher` reference is dropped immediately after `stop()`.
/// `teardown()` additionally drains the callback queue synchronously, so once
/// `stop()` returns no callback is still executing.
public final class DirectoryWatcher {

    /// The object FSEvents retains as its context `info`. Holds only the
    /// immutable change handler; events are delivered by hopping to the main
    /// actor. `@unchecked Sendable`: the single stored property is a `let`
    /// main-actor closure that is only ever *invoked* on the main actor.
    private final class EventSink: @unchecked Sendable {
        private let onChange: @MainActor (Set<String>) -> Void

        init(onChange: @escaping @MainActor (Set<String>) -> Void) {
            self.onChange = onChange
        }

        /// Hop the changed-path set to the main actor and invoke `onChange`.
        func deliver(_ dirs: Set<String>) {
            guard !dirs.isEmpty else { return }
            let handler = onChange
            Task { @MainActor in handler(dirs) }
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.lume.DirectoryWatcher", qos: .utility)

    /// Start watching `root` (recursively). `onChange` receives the set of
    /// changed directory paths on the main actor.
    public init(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
        start(root: root, sink: EventSink(onChange: onChange))
    }

    deinit {
        // `teardown()` is safe to call off the main actor: it only touches the
        // FSEvents stream handle and the private queue, never the sink.
        teardown()
    }

    private func start(root: URL, sink: EventSink) {
        // passUnretained + retain/release callbacks: FSEventStreamCreate copies
        // the context and takes its OWN +1 on the sink via `retain`, balanced
        // by `release` after the stream is invalidated and its pending queue
        // work has completed. The sink's lifetime is therefore owned by
        // FSEvents, not by this watcher, which closes the use-after-free
        // window on teardown.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventSink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
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
            sink.deliver(dirs)
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

    /// Stop watching and release the FSEvents stream. Idempotent.
    public func stop() {
        teardown()
    }

    private func teardown() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Drain the callback queue: any event callback that was already
        // executing has finished by the time this returns. This can never
        // deadlock — nothing in this class runs `teardown()` ON `queue`
        // (the sink never references the watcher, so even the final release
        // of `self` cannot occur there).
        queue.sync {}
    }
}
