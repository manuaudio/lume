import Foundation
import Observation

/// Drives favorites sync: projects local state → reconciles against the shared
/// iCloud document → applies the result back into the stores → pushes the merged
/// document. The pure merge lives in `SyncMerge`; this shell owns the I/O and the
/// store wiring. Lives in LumeKit (holds `LibraryStore`/`ConnectionStore`); the
/// app sets `onApplied` to refresh its projections.
@MainActor
@Observable
public final class FavoritesSyncEngine {
    private let library: LibraryStore
    private let connections: ConnectionStore
    private let store: any SyncDocumentStore
    private let now: () -> Date

    /// Called after an incoming merge mutates the stores, so the app can refresh.
    public var onApplied: (() -> Void)?

    /// True while applying an incoming merge — suppresses the outbound trigger so
    /// an applied change can't re-stamp and ping-pong.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var debounce: Task<Void, Never>?

    public init(library: LibraryStore, connections: ConnectionStore,
                store: any SyncDocumentStore, now: @escaping () -> Date = Date.init) {
        self.library = library
        self.connections = connections
        self.store = store
        self.now = now
    }

    /// Debounced outbound sync, called after a local pin/unpin or host change.
    public func scheduleSync() {
        guard !isApplying, store.isAvailable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// One full reconcile pass. Safe to call directly (launch, metadata change).
    public func sync() {
        guard store.isAvailable else { return }
        let baseline = store.readBaseline()
        let local = projectLocal()
        let incoming = (try? store.readShared()) ?? SyncDocument()
        let merged = SyncMerge.reconcile(baseline: baseline, local: local,
                                         incoming: incoming, now: now())
        apply(merged)
        try? store.writeShared(merged)
        store.writeBaseline(merged)
    }

    // MARK: - Local projection

    private func projectLocal() -> SyncDocument {
        let favs = library.remoteFavorites().map {
            RemoteFavoriteRecord(ref: $0.ref, sourceKind: $0.sourceKindRaw, sourceKey: $0.sourceKey,
                                 path: $0.path, isDirectory: $0.isDirectory,
                                 updatedAt: .distantPast, deleted: false)   // time set by reconcile
        }
        let hosts = connections.state.manualHosts.map {
            ManualHostRecord(alias: $0.alias, hostname: $0.hostname, user: $0.user, port: $0.port,
                             identityFile: Self.tildeRelative($0.identityFile),
                             updatedAt: .distantPast, deleted: false)
        }
        return SyncDocument(remoteFavorites: favs, manualHosts: hosts)
    }

    // MARK: - Apply merged → stores (guarded)

    private func apply(_ merged: SyncDocument) {
        isApplying = true
        defer { isApplying = false }
        var changed = false

        // Remote favorites: upsert desired, remove the rest.
        let desiredFavs = merged.remoteFavorites.filter { !$0.deleted }
        let desiredRefs = Set(desiredFavs.map(\.ref))
        for rec in desiredFavs where !library.isRemoteFavorite(ref: rec.ref) {
            library.addRemoteFavorite(ref: rec.ref, sourceKind: rec.sourceKind, sourceKey: rec.sourceKey,
                                      path: rec.path, isDirectory: rec.isDirectory)
            changed = true
        }
        for existing in library.remoteFavorites() where !desiredRefs.contains(existing.ref) {
            library.removeRemoteFavorite(ref: existing.ref)
            changed = true
        }

        // Manual hosts: upsert desired (tilde expanded for this Mac), remove the rest.
        let desiredHosts = merged.manualHosts.filter { !$0.deleted }
        let desiredAliases = Set(desiredHosts.map(\.alias))
        let currentByAlias = Dictionary(uniqueKeysWithValues: connections.state.manualHosts.map { ($0.alias, $0) })
        for rec in desiredHosts {
            let host = SSHHost(alias: rec.alias, hostname: rec.hostname, user: rec.user,
                               port: rec.port, identityFile: Self.tildeExpanded(rec.identityFile))
            if currentByAlias[rec.alias] != host {
                connections.addManualHost(host)   // upsert (replaces same alias)
                changed = true
            }
        }
        for existing in connections.state.manualHosts where !desiredAliases.contains(existing.alias) {
            connections.removeManualHost(alias: existing.alias)
            changed = true
        }

        if changed { onApplied?() }
    }

    // MARK: - identityFile portability

    /// `/Users/manu/.ssh/id` → `~/.ssh/id` when under the home dir (so the path
    /// resolves on another Mac with a different username). Other paths unchanged.
    static func tildeRelative(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Inverse: expands a leading `~` to THIS Mac's home dir.
    static func tildeExpanded(_ path: String?) -> String? {
        guard let path else { return nil }
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSString(string: path).expandingTildeInPath
    }
}
