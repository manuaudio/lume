import Foundation
@testable import LumeKit

/// In-memory `FileSource` for tests. `dirs` maps a directory path to its
/// listing; `files` maps a file path to its UTF-8 contents.
struct FakeFileSource: FileSource {
    let id: SourceID
    let dirs: [String: [ResourceNode]]
    let files: [String: String]

    init(id: SourceID, dirs: [String: [ResourceNode]], files: [String: String] = [:]) {
        self.id = id
        self.dirs = dirs
        self.files = files
    }

    func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        guard let listing = dirs[path] else { throw FakeError.notFound(path) }
        return listing
    }

    func read(_ path: String) async throws -> String {
        guard let text = files[path] else { throw FakeError.notFound(path) }
        return text
    }

    func write(_ text: String, to path: String) async throws {
        throw FakeError.unsupported
    }

    func stat(_ path: String) async throws -> ResourceMeta {
        if let text = files[path] {
            return ResourceMeta(isDirectory: false, size: Int64(text.utf8.count))
        }
        if dirs[path] != nil { return ResourceMeta(isDirectory: true) }
        throw FakeError.notFound(path)
    }

    enum FakeError: Error { case notFound(String), unsupported }
}

/// Convenience for building `ResourceNode`s in tests.
func node(_ sourceID: SourceID, _ path: String, dir: Bool, symlink: Bool = false) -> ResourceNode {
    ResourceNode(ref: ResourceRef(sourceID: sourceID, path: path),
                 isDirectory: dir, isSymlink: symlink)
}
