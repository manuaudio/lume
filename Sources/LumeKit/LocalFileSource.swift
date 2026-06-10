import Foundation

/// `FileSource` over the local disk. Wraps the existing `FileService`
/// enumeration rules and `TextDocument` coordinated load/save so behavior is
/// identical to the pre-abstraction code paths.
public struct LocalFileSource: FileSource {
    public let id: SourceID = .local
    private let files: FileServicing

    public init(files: FileServicing = FileService()) {
        self.files = files
    }

    public func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode] {
        let url = URL(fileURLWithPath: path)
        return try files.enumerate(url, includeHidden: includeHidden).map { node in
            ResourceNode(
                ref: ResourceRef(sourceID: .local, path: node.url.path),
                isDirectory: node.isDirectory
            )
        }
    }

    public func read(_ path: String) async throws -> String {
        try await TextDocument.load(URL(fileURLWithPath: path)).text
    }

    public func write(_ text: String, to path: String) async throws {
        let url = URL(fileURLWithPath: path)
        try await Task.detached(priority: .userInitiated) {
            try TextDocument(url: url, text: text).save()
        }.value
    }

    public func stat(_ path: String) async throws -> ResourceMeta {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let type = attrs[.type] as? FileAttributeType
        return ResourceMeta(
            isDirectory: type == .typeDirectory,
            size: (attrs[.size] as? NSNumber)?.int64Value,
            mode: (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        )
    }
}
