import Foundation

/// One entry in a browsed folder. Identity is the URL.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }
}
