import Foundation

/// Coordinates reads of iCloud files that may be evicted placeholders.
///
/// The cowork folder lives under `com~apple~CloudDocs`, so a file's bytes may
/// not be local. Before reading we request a download and wait for the item to
/// materialize — but never on the main thread, so the UI never freezes.
enum ICloudCoordinator {
    /// True if the item is local and ready to read right now (or is not an
    /// iCloud item at all). Cheap, non-blocking — safe to call on the main thread.
    static func isReady(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else {
            // Not an iCloud item — always ready.
            return true
        }
        return status == .current
    }

    /// Ensure an evicted iCloud placeholder is materialized, then call `completion`
    /// on the main thread. If the item is already local (or not in iCloud) this
    /// calls back immediately. The download polling happens on a background queue,
    /// so the caller's thread is never blocked.
    static func ensureDownloaded(_ url: URL, completion: @escaping @MainActor () -> Void) {
        if isReady(url) {
            MainActor.assumeIsolated(completion)
            return
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        DispatchQueue.global(qos: .userInitiated).async {
            // Poll on a background queue (up to ~5s) so the main thread stays free.
            for _ in 0..<50 {
                if isReady(url) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated(completion) }
        }
    }
}
