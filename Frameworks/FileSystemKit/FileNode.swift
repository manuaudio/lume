import Foundation

/// A node in the file tree. `children == nil` means "not a directory" or
/// "directory not yet expanded"; the sidebar loads children lazily.
public struct FileNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public var children: [FileNode]?
    public var id: URL { url }

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    public var name: String { url.lastPathComponent }
    public var kind: FileKind { FileKind.detect(filename: name) }
}
