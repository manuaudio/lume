import Foundation

/// Thin UserDefaults wrapper. Stores a security-scoped bookmark to the last
/// opened folder so it reopens across launches without re-prompting.
enum Preferences {
    private static let lastFolderBookmarkKey = "lastFolderBookmark"

    static func saveLastFolder(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: lastFolderBookmarkKey)
    }

    /// Returns the last folder if its bookmark resolves. Caller is responsible
    /// for calling `startAccessingSecurityScopedResource()` on the result.
    static func loadLastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: lastFolderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return url
    }
}
