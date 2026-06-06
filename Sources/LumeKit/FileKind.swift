import Foundation
import UniformTypeIdentifiers

/// Classifies a file URL into how Lume should present it.
public enum FileKind: Equatable, Sendable {
    case markdown
    case text
    case other

    public init(url: URL) {
        let ext = url.pathExtension.lowercased()
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "markdn"]
        if markdownExtensions.contains(ext) {
            self = .markdown
            return
        }
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           type.conforms(to: .text) {
            self = .text
            return
        }
        self = .other
    }
}
