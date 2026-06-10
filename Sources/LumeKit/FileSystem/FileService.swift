import Foundation

public protocol FileServicing: Sendable {
    /// List a directory's children. When `includeHidden` is true, filesystem
    /// dotfiles (`.env`, `.claude`, `.gitignore`, …) are revealed; either way the
    /// always-noise names below are filtered.
    func enumerate(_ directory: URL, includeHidden: Bool) throws -> [FileNode]
    func read(_ url: URL) throws -> String
    func write(_ text: String, to url: URL) throws
}

public extension FileServicing {
    /// Convenience: enumerate with dotfiles hidden (the default tree view).
    func enumerate(_ directory: URL) throws -> [FileNode] {
        try enumerate(directory, includeHidden: false)
    }
}

public struct FileService: FileServicing {
    /// Names that are never shown in the tree, even with "Show hidden" on —
    /// pure noise the user never curates.
    private static let ignoredNames: Set<String> = [
        ".DS_Store", "node_modules", ".git", ".build", ".svn",
    ]

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
            if Self.ignoredNames.contains(name) { return nil }
            // Hide dotfiles unless "Show hidden" is on. `.env*` stays visible
            // either way (it's a curated config, not noise).
            if !includeHidden, name.hasPrefix("."), name != ".env", !name.hasPrefix(".env.") { return nil }
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

    public func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
