import Foundation

/// Coordinates reads of iCloud files that may be evicted placeholders.
///
/// The cowork folder lives under `com~apple~CloudDocs`, so a file's bytes may
/// not be local. Before reading we request a download and wait for the item to
/// materialize — but never on the main thread, so the UI never freezes.
enum ICloudCoordinator {
    /// True if the item is local and ready to read right now (or is not an
    /// iCloud item at all). NOTE: `resourceValues` can block on the iCloud daemon
    /// when it is busy — call this OFF the main thread (both `ensureDownloaded`
    /// entry points below now do).
    static func isReady(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else {
            // Not an iCloud item — always ready.
            return true
        }
        return status == .current
    }

    /// Ensure an evicted iCloud placeholder is materialized. Suspends (without
    /// blocking any thread) until the item is local — or returns immediately if
    /// it already is, or isn't an iCloud file. Gives up after ~5s.
    static func ensureDownloaded(_ url: URL) async {
        if isReady(url) { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        // Poll via structured concurrency: `Task.sleep` suspends the task without
        // tying up a thread (vs. the old `Thread.sleep` on a background queue).
        for _ in 0..<50 {
            if isReady(url) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Completion convenience over the async API: materializes the item, then
    /// calls `completion` on the main actor. The readiness check and any download
    /// wait run off the main thread (this is a nonisolated static, so the `Task`
    /// runs on the cooperative pool), so a slow/busy iCloud daemon never blocks
    /// the click frame — even for an already-local file.
    static func ensureDownloaded(_ url: URL, completion: @escaping @MainActor () -> Void) {
        Task {
            await ensureDownloaded(url)
            await MainActor.run { completion() }
        }
    }
}
