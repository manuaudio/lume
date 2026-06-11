import Foundation

public protocol FileServicing: Sendable {
    /// List a directory's children. When `includeHidden` is true, filesystem
    /// dotfiles (`.env`, `.claude`, `.gitignore`, …) are revealed; either way the
    /// always-noise names below are filtered.
    func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode]
}

public extension FileServicing {
    /// Convenience: enumerate with dotfiles hidden (the default tree view).
    func enumerate(_ directory: URL) throws -> [FileNode] {
        try enumerate(directory, includeHidden: false)
    }
}

public struct FileService: FileServicing {
    public init() {}

    public func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        )
        let nodes: [FileNode] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard TreeFilterRules.isVisible(name: name, includeHidden: includeHidden) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink ?? false
            // Symlinks are listed but NEVER treated as directories (matching
            // ScanEngine's symlink skip): reporting them as leaves means the
            // sidebar can't expand into a target outside the opened tree.
            let isDir = !isSymlink && (values?.isDirectory ?? false)
            return FileNode(url: url, isDirectory: isDir, isSymlink: isSymlink, children: nil)
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory } // folders first
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
