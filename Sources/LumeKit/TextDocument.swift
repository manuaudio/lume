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

    /// Reads the file as UTF-8 on a background task, coordinated via
    /// `NSFileCoordinator` so an iCloud / ubiquitous file is downloaded and we
    /// read a consistent snapshot even while other processes touch it.
    public static func load(_ url: URL) async throws -> TextDocument {
        let text = try await Task.detached(priority: .userInitiated) {
            // Best-effort: kick off a download if the item lives in iCloud and
            // isn't local yet. Harmless (and ignored) for ordinary files.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return try Self.coordinatedRead(url)
        }.value
        return TextDocument(url: url, text: text)
    }

    /// Atomically writes the current text back to its file, coordinated so iCloud
    /// and other readers see a clean replacement.
    public func save() throws {
        var coordinationError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { writeURL in
            do { try text.write(to: writeURL, atomically: true, encoding: .utf8) }
            catch { ioError = error }
        }
        if let coordinationError { throw coordinationError }
        if let ioError { throw ioError }
    }

    private static func coordinatedRead(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            result = Result { try String(contentsOf: readURL, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
}
