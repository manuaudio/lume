import Foundation

/// Coordinates reads of iCloud files that may be evicted placeholders.
///
/// The cowork folder lives under `com~apple~CloudDocs`, so a file's bytes may
/// not be local. Before reading we request a download and wait briefly for the
/// item to materialize.
enum ICloudCoordinator {
    /// If `url` is an evicted iCloud placeholder, request its download and wait
    /// briefly for it to materialize. Safe to call on any file, iCloud or not.
    static func ensureDownloaded(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else {
            // Not an iCloud item — nothing to do.
            return
        }
        if status == .current { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        // Poll briefly (up to ~5s). The caller can show a spinner if desired.
        for _ in 0..<50 {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
