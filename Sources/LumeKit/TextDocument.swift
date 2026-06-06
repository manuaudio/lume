import Foundation

/// An in-memory text document backed by a file. Loading and saving happen off
/// the main thread; the original prototype froze the UI by reading on main.
public struct TextDocument: Equatable, Sendable {
    public let url: URL
    public var text: String

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }

    /// Reads the file as UTF-8 on a background task.
    public static func load(_ url: URL) async throws -> TextDocument {
        let text = try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
        return TextDocument(url: url, text: text)
    }

    /// Atomically writes the current text back to its file.
    public func save() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
