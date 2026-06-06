import Foundation

/// Enumerates a single directory level into sorted `FileNode`s.
/// Non-recursive by design: directories are expanded lazily by the UI so
/// opening a large folder never walks the whole tree on the main thread.
public struct FolderScanner: Sendable {
    public init() {}

    public func scan(_ directory: URL, includeHidden: Bool = false) throws -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )

        let nodes = try urls.map { url -> FileNode in
            let values = try url.resourceValues(forKeys: Set(keys))
            return FileNode(
                url: url,
                name: values.name ?? url.lastPathComponent,
                isDirectory: values.isDirectory ?? false
            )
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
