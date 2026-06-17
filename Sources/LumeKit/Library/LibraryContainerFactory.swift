import Foundation
import SwiftData
import os

/// How persistent-store setup went at launch. Anything but `.healthy` must be
/// surfaced by the app layer — the user's library is degraded.
public enum StoreHealth: Equatable, Sendable {
    /// The persistent store opened (or was freshly created) normally.
    case healthy
    /// The existing store couldn't be opened; it was moved aside to `backupURL`
    /// (nil if the move itself failed) and a fresh persistent store was created.
    /// Favorites/tags/notes start empty but WILL persist from now on.
    case recoveredFromCorruption(backupURL: URL?)
    /// No persistent store could be created at all. The library is in-memory:
    /// nothing will persist across launches.
    case ephemeral
}

/// Creates the app's `ModelContainer` with corrupt-store recovery (audit A3):
/// open normally → on failure move the store aside (timestamped, preserving the
/// user's data for recovery) and retry fresh → only then fall back to in-memory,
/// always reporting what happened. Never `try!`, never silent.
public enum LibraryContainerFactory {
    private static let logger = Logger(subsystem: "com.lume.LumeKit", category: "LibraryContainerFactory")

    /// `storeURL` overrides the default Application Support location (tests).
    public static func make(at storeURL: URL? = nil) -> (container: ModelContainer, health: StoreHealth) {
        let schema = Schema(versionedSchema: LumeSchemaV2.self)
        let config: ModelConfiguration = if let storeURL {
            ModelConfiguration(schema: schema, url: storeURL)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        // 1) Normal path.
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: LumeMigrationPlan.self, configurations: [config]
            )
            return (container, .healthy)
        } catch {
            logger.error("persistent store failed to open: \(error.localizedDescription, privacy: .public)")
        }

        // 2) Move the unreadable store aside and retry with a fresh one.
        let backupURL = moveStoreAside(config.url)
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: LumeMigrationPlan.self, configurations: [config]
            )
            return (container, .recoveredFromCorruption(backupURL: backupURL))
        } catch {
            logger.error("fresh persistent store also failed: \(error.localizedDescription, privacy: .public)")
        }

        // 3) Last resort: in-memory, visibly ephemeral.
        do {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: schema, migrationPlan: LumeMigrationPlan.self, configurations: [memory]
            )
            return (container, .ephemeral)
        } catch {
            // In-memory creation can only fail on a schema programming error,
            // and the app cannot run without a container — crash with a real
            // message instead of the old anonymous `try!`.
            fatalError("Lume could not create even an in-memory model container: \(error)")
        }
    }

    /// Rename `…/default.store` (+ SQLite `-shm`/`-wal` sidecars) to timestamped
    /// `.corrupt-…` siblings so the user's data survives for inspection or
    /// recovery. Returns the main store file's new URL, or nil if nothing moved.
    private static func moveStoreAside(_ storeURL: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let destination = storeURL.appendingPathExtension("corrupt-\(formatter.string(from: .now))")
        do {
            try fm.moveItem(at: storeURL, to: destination)
        } catch {
            logger.error("couldn't move corrupt store aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Sidecars are best-effort: a stale -wal left beside a FRESH store is
        // exactly the corruption vector we're closing, so move them too.
        for ext in ["-shm", "-wal"] {
            try? fm.moveItem(
                at: URL(fileURLWithPath: storeURL.path + ext),
                to: URL(fileURLWithPath: destination.path + ext)
            )
        }
        return destination
    }
}
