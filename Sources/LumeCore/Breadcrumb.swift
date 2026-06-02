import Foundation

/// Pure computation of the clickable path-bar segments for the browser.
public enum Breadcrumb {
    public struct Segment: Equatable, Identifiable, Sendable {
        public let label: String
        public let url: URL
        public var id: String { url.path }
    }

    /// Ancestor segments from a root (home shown as `~`, otherwise `/`) up to and
    /// including `current`.
    public static func segments(for current: URL, home: URL) -> [Segment] {
        let cur = current.standardizedFileURL
        let homeStd = home.standardizedFileURL

        // Build the list of path components as URLs, from filesystem root down.
        var urls: [URL] = []
        var walk = cur
        while true {
            urls.append(walk)
            let parent = walk.deletingLastPathComponent()
            if parent.path == walk.path { break }   // reached "/"
            walk = parent
        }
        urls.reverse() // root → current

        // Trim everything above home when current is inside home.
        if cur.path == homeStd.path || cur.path.hasPrefix(homeStd.path + "/") {
            urls = urls.filter { $0.path == homeStd.path || $0.path.hasPrefix(homeStd.path + "/") }
        }

        return urls.map { url in
            let label: String
            if url.path == homeStd.path { label = "~" }
            else if url.path == "/" { label = "/" }
            else { label = url.lastPathComponent }
            return Segment(label: label, url: url)
        }
    }
}
