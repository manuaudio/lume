import Foundation
import os

/// Reads/writes the shared sync document and the local baseline. Abstracted so
/// the engine is testable with an in-memory fake and so the iCloud dependency
/// is one swappable, thin implementation.
public protocol SyncDocumentStore: Sendable {
    /// Whether sync can run (iCloud signed in + ubiquity container resolved).
    var isAvailable: Bool { get }
    /// The shared iCloud document; an absent/unreadable file reads as empty.
    func readShared() throws -> SyncDocument
    /// Replace the shared iCloud document (coordinated). No-op when unavailable.
    func writeShared(_ doc: SyncDocument) throws
    /// The last-merged baseline persisted locally; empty if none.
    func readBaseline() -> SyncDocument
    /// Persist the baseline locally.
    func writeBaseline(_ doc: SyncDocument)
}

/// iCloud-backed store. The shared document lives in the ubiquity container's
/// Documents; the baseline lives in Application Support (never synced). URLs are
/// injectable so tests exercise the real coordinated I/O against temp files; a
/// nil `sharedURL` models "iCloud unavailable" (the dev/ad-hoc-signed reality).
public struct UbiquityDocumentStore: SyncDocumentStore {
    private let sharedURL: URL?
    private let baselineURL: URL
    private static let logger = Logger(subsystem: "com.lume.LumeKit", category: "Sync")

    /// Production locator: nil sharedURL when no ubiquity container is available.
    public static func make() -> UbiquityDocumentStore {
        let ubiquity = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?     // nil → the app's primary container
            .appendingPathComponent("Documents/favorites-sync.json")
        let baseline = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume/favorites-sync-baseline.json")
        return UbiquityDocumentStore(sharedURL: ubiquity, baselineURL: baseline)
    }

    public init(sharedURL: URL?, baselineURL: URL) {
        self.sharedURL = sharedURL
        self.baselineURL = baselineURL
    }

    public var isAvailable: Bool { sharedURL != nil }

    public func readShared() throws -> SyncDocument {
        guard let sharedURL else { return SyncDocument() }
        return Self.coordinatedRead(sharedURL)
    }

    public func writeShared(_ doc: SyncDocument) throws {
        guard let sharedURL else { return }    // unavailable → no-op
        try Self.coordinatedWrite(doc, to: sharedURL)
    }

    public func readBaseline() -> SyncDocument {
        (try? Self.decode(Data(contentsOf: baselineURL))) ?? SyncDocument()
    }

    public func writeBaseline(_ doc: SyncDocument) {
        do {
            try FileManager.default.createDirectory(
                at: baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(doc).write(to: baselineURL, options: .atomic)
        } catch {
            Self.logger.error("baseline write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Coordinated file I/O + JSON

    /// A read that can't decode (absent, partial iCloud download, corrupt) yields
    /// an empty document — favorites are never lost to a bad file.
    private static func coordinatedRead(_ url: URL) -> SyncDocument {
        var result = SyncDocument()
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            if let data = try? Data(contentsOf: readURL), let doc = try? decode(data) {
                result = doc
            }
        }
        return result
    }

    private static func coordinatedWrite(_ doc: SyncDocument, to url: URL) throws {
        let data = try encode(doc)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try FileManager.default.createDirectory(
                    at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: writeURL, options: .atomic)
            } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    private static func encode(_ doc: SyncDocument) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(doc)
    }

    private static func decode(_ data: Data) throws -> SyncDocument {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SyncDocument.self, from: data)
    }
}
