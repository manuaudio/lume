import Foundation

/// The three-way merge at the heart of favorites sync. Pure and time-injected
/// (`now`), so it is fully unit-testable without iCloud.
public enum SyncMerge {
    /// Tombstones older than this (relative to the injected `now`) are pruned to
    /// bound document growth. 30 days gives every still-online peer ample time to
    /// observe a deletion before its record disappears — shrink this and a peer
    /// that was offline for the window would resurrect a deleted favorite.
    public static let tombstoneHorizon: TimeInterval = 30 * 24 * 3600

    /// Reconcile this Mac's `local` projection against the last-synced
    /// `baseline` and the `incoming` iCloud document.
    /// - `local` items carry CURRENT fields; their timestamps are ignored —
    ///   the merge derives each item's effective `updatedAt` by diffing local
    ///   against baseline (changed/new → `now`; unchanged → baseline's time;
    ///   vanished → tombstone at `now`).
    public static func reconcile(baseline: SyncDocument, local: SyncDocument,
                                 incoming: SyncDocument, now: Date) -> SyncDocument {
        SyncDocument(
            schemaVersion: 1,
            remoteFavorites: reconcileList(baseline: baseline.remoteFavorites,
                                           local: local.remoteFavorites,
                                           incoming: incoming.remoteFavorites, now: now),
            manualHosts: reconcileList(baseline: baseline.manualHosts,
                                       local: local.manualHosts,
                                       incoming: incoming.manualHosts, now: now)
        )
    }

    static func reconcileList<R: SyncRecord>(baseline: [R], local: [R],
                                             incoming: [R], now: Date) -> [R] {
        let b = Dictionary(uniqueKeysWithValues: baseline.map { ($0.identity, $0) })
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.identity, $0) })
        let inc = Dictionary(uniqueKeysWithValues: incoming.map { ($0.identity, $0) })
        let ids = Set(b.keys).union(l.keys).union(inc.keys)

        var out: [R] = []
        for id in ids {
            // Effective local record + timestamp, derived against the baseline.
            let localEff: R?
            if let cur = l[id] {
                if let base = b[id], !base.deleted, cur.sameFields(as: base) {
                    localEff = cur.stamped(at: base.updatedAt)   // unchanged since baseline
                } else {
                    localEff = cur.stamped(at: now)              // new or edited locally
                }
            } else if let base = b[id], !base.deleted {
                localEff = base.tombstoned(at: now)              // deleted locally
            } else {
                localEff = b[id]                                 // carry an existing tombstone (or nil)
            }

            // Last-writer-wins between local-effective and incoming.
            let winner = [localEff, inc[id]].compactMap { $0 }
                .max { $0.updatedAt < $1.updatedAt }
            guard let winner else { continue }
            // Prune long-dead tombstones.
            if winner.deleted, now.timeIntervalSince(winner.updatedAt) > tombstoneHorizon { continue }
            out.append(winner)
        }
        return out.sorted { $0.identity < $1.identity }   // deterministic order
    }
}
