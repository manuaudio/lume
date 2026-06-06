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
        //
        // Only an absolute file URL has a parent chain that terminates at "/".
        // For a relative or non-file URL, `deletingLastPathComponent()` prepends
        // "../" forever and never reaches a fixed point — the original
        // `while true` loop grew `urls` unbounded (31 GB → CPU kill). Guard on
        // file-URL-ness, require the path to strictly shrink each step, and cap
        // iterations as a final backstop against any unforeseen non-terminating
        // case.
        let maxDepth = 64
        var urls: [URL] = []
        var walk = cur
        while urls.count < maxDepth {
            urls.append(walk)
            guard walk.isFileURL, !walk.path.isEmpty else { break }
            let parent = walk.deletingLastPathComponent()
            guard parent.path.count < walk.path.count else { break }   // reached "/" (no shrink)
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
