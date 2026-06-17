import Foundation

/// The JSON sync document — the wire format mirrored across a user's Macs via
/// iCloud. Pure data; `SyncMerge` reconciles two of these. Timestamps/tombstones
/// live ONLY here and in the engine, never in the SwiftData models.
public struct SyncDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var remoteFavorites: [RemoteFavoriteRecord]
    public var manualHosts: [ManualHostRecord]

    public init(schemaVersion: Int = 1,
                remoteFavorites: [RemoteFavoriteRecord] = [],
                manualHosts: [ManualHostRecord] = []) {
        self.schemaVersion = schemaVersion
        self.remoteFavorites = remoteFavorites
        self.manualHosts = manualHosts
    }
}

/// One synced remote favorite. `ref` is the identity; `updatedAt`/`deleted` are
/// the LWW + tombstone metadata.
public struct RemoteFavoriteRecord: Codable, Equatable, Sendable, SyncRecord {
    public var ref: String
    public var sourceKind: String
    public var sourceKey: String
    public var path: String
    public var isDirectory: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(ref: String, sourceKind: String, sourceKey: String, path: String,
                isDirectory: Bool, updatedAt: Date, deleted: Bool) {
        self.ref = ref; self.sourceKind = sourceKind; self.sourceKey = sourceKey
        self.path = path; self.isDirectory = isDirectory
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    public var identity: String { ref }
    public func sameFields(as other: RemoteFavoriteRecord) -> Bool {
        sourceKind == other.sourceKind && sourceKey == other.sourceKey
            && path == other.path && isDirectory == other.isDirectory
    }
    public func tombstoned(at date: Date) -> RemoteFavoriteRecord {
        var c = self; c.deleted = true; c.updatedAt = date; return c
    }
    public func stamped(at date: Date) -> RemoteFavoriteRecord {
        var c = self; c.updatedAt = date; return c
    }
}

/// One synced manual SSH connection. `alias` is the identity. `identityFile` is
/// a PATH string only — the private key is never synced.
public struct ManualHostRecord: Codable, Equatable, Sendable, SyncRecord {
    public var alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var updatedAt: Date
    public var deleted: Bool

    public init(alias: String, hostname: String?, user: String?, port: Int?,
                identityFile: String?, updatedAt: Date, deleted: Bool) {
        self.alias = alias; self.hostname = hostname; self.user = user
        self.port = port; self.identityFile = identityFile
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    public var identity: String { alias }
    public func sameFields(as other: ManualHostRecord) -> Bool {
        hostname == other.hostname && user == other.user
            && port == other.port && identityFile == other.identityFile
    }
    public func tombstoned(at date: Date) -> ManualHostRecord {
        var c = self; c.deleted = true; c.updatedAt = date; return c
    }
    public func stamped(at date: Date) -> ManualHostRecord {
        var c = self; c.updatedAt = date; return c
    }
}

/// Shared shape that lets `SyncMerge` reconcile both record kinds generically.
public protocol SyncRecord: Equatable {
    var identity: String { get }
    var updatedAt: Date { get }
    var deleted: Bool { get }
    func sameFields(as other: Self) -> Bool
    func tombstoned(at date: Date) -> Self
    func stamped(at date: Date) -> Self
}
