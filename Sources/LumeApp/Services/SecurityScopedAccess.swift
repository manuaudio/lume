import Foundation

/// Persists access to a user-selected folder across launches via a
/// security-scoped bookmark. Required under the App Sandbox (a stored *path*
/// grants no access on relaunch); harmless and equivalent to a normal bookmark
/// when unsandboxed, so it's always safe to use.
///
/// Access to a folder transitively covers its subtree, so bookmarking the root
/// the user opened is enough to browse into its children.
@MainActor
enum SecurityScopedAccess {
    /// The URL currently being accessed, so we balance start/stop correctly.
    private static var active: URL?

    /// Save a security-scoped bookmark for `url` under `key`.
    static func store(_ url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Unsandboxed builds may reject `.withSecurityScope`; the plain-path
            // fallback in AppModel still restores the folder, so this is non-fatal.
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Resolve the bookmark at `key`, begin accessing it (releasing any prior
    /// scope), and return the URL — or nil if there's no usable bookmark.
    static func resolve(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        beginAccess(url)
        // Refresh a stale bookmark so access keeps working after the OS rotates it.
        if stale { store(url, key: key) }
        return url
    }

    /// Begin accessing `url`, stopping access to whatever we held before.
    static func beginAccess(_ url: URL) {
        if let active, active != url {
            active.stopAccessingSecurityScopedResource()
        }
        if url.startAccessingSecurityScopedResource() {
            active = url
        }
    }
}
