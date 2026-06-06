import Foundation

/// Pure naming helpers for filesystem operations (New Folder, Duplicate). The
/// collision-avoidance logic is isolated here — and parameterized on an `exists`
/// probe — so it can be unit-tested without touching the disk.
public enum FileOps {

    /// A non-colliding URL for a new child of `parent` named `base` (optionally
    /// with extension `ext`). Appends " 2", " 3"… before the extension until the
    /// name is free. `exists` is injectable for testing.
    public static func uniqueChild(
        in parent: URL,
        base: String,
        ext: String = "",
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        func make(_ name: String) -> URL {
            let child = parent.appendingPathComponent(name)
            return ext.isEmpty ? child : child.appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while exists(candidate) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// The Finder-style duplicate URL for `url`: "<stem> copy", then
    /// "<stem> copy 2"… keeping the original extension.
    public static func duplicateURL(
        for url: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        return uniqueChild(in: dir, base: "\(stem) copy", ext: ext, exists: exists)
    }
}
