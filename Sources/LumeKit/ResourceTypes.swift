import Foundation

/// Which backend a resource lives in. `.local` is the on-disk workspace;
/// `.ssh` is a connected remote host (keyed by its alias/nickname);
/// `.github` is a GitHub repository (keyed by "owner/repo"; the active
/// branch is session state, not identity).
public enum SourceID: Hashable, Sendable {
    case local
    case ssh(alias: String)
    case github(slug: String)
}

/// Identifies a resource within some source — replaces "everything is a
/// local URL" for code that must work across local and remote backends.
public struct ResourceRef: Hashable, Sendable {
    public let sourceID: SourceID
    public let path: String          // absolute path within the source

    public init(sourceID: SourceID, path: String) {
        self.sourceID = sourceID
        self.path = path
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Best-effort metadata for one resource (what `ls -la` / `stat` can tell us).
public struct ResourceMeta: Equatable, Sendable {
    public let isDirectory: Bool
    public let size: Int64?
    public let mode: UInt16?         // POSIX permission bits when known

    public init(isDirectory: Bool, size: Int64? = nil, mode: UInt16? = nil) {
        self.isDirectory = isDirectory
        self.size = size
        self.mode = mode
    }
}

/// A node in a source's tree — `FileNode` generalized. `children == nil`
/// means "not a directory" or "directory not yet expanded" (same lazy
/// contract the local sidebar uses).
public struct ResourceNode: Identifiable, Equatable, Sendable {
    public let ref: ResourceRef
    public let isDirectory: Bool
    public let isSymlink: Bool
    public var children: [ResourceNode]?

    public init(ref: ResourceRef, isDirectory: Bool, isSymlink: Bool = false, children: [ResourceNode]? = nil) {
        self.ref = ref
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.children = children
    }

    public var id: ResourceRef { ref }
    public var name: String { ref.name }
    public var kind: FileKind { FileKind.detect(filename: name) }
}
