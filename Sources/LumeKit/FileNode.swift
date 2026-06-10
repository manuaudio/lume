import Foundation

/// A node in the file tree. `children == nil` means "not a directory" or
/// "directory not yet expanded"; the sidebar loads children lazily.
public struct FileNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// True for symbolic links. Symlinks are listed as LEAF rows and never
    /// enumerated into — the target may point outside the opened tree
    /// (e.g. a link to ~/.ssh must not expose its contents in the browser).
    public let isSymlink: Bool
    public var children: [FileNode]?
    public var id: URL { url }

    public init(url: URL, isDirectory: Bool, isSymlink: Bool = false, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.children = children
    }

    public var name: String { url.lastPathComponent }
    public var kind: FileKind { FileKind.detect(filename: name) }
}
