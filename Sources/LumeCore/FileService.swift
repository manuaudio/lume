import Foundation

public protocol FileServicing: Sendable {
    func enumerate(_ directory: URL) throws -> [FileNode]
    func read(_ url: URL) throws -> String
    func write(_ text: String, to url: URL) throws
}

public struct FileService: FileServicing {
    /// Names that are never shown in the tree.
    private static let ignoredNames: Set<String> = [
        ".DS_Store", "node_modules", ".git", ".build", ".svn",
    ]

    public init() {}

    public func enumerate(_ directory: URL) throws -> [FileNode] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )
        let nodes: [FileNode] = entries.compactMap { url in
            let name = url.lastPathComponent
            if Self.ignoredNames.contains(name) { return nil }
            // Hide dotfiles except .env*.
            if name.hasPrefix("."), name != ".env", !name.hasPrefix(".env.") { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileNode(url: url, isDirectory: isDir, children: nil)
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
