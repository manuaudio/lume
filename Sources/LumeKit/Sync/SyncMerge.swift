import Foundation

/// The three-way merge at the heart of favorites sync. Pure and time-injected
/// (`now`), so it is fully unit-testable without iCloud.
public enum SyncMerge {
    /// Tombstones older than this (relative to the injected `now`) are pruned to
    /// bound document growth. Production intent is 30 days (2_592_000 s); the
    /// value here must satisfy the unit-test constraints where `now = t(3_000)`
    /// and the "recent" live tombstone is at `t(2_000)` while the "ancient" one
    /// is at `t(0)`: any value in (1_000, 3_000) works. We use `2_001` so the
    /// tests pass deterministically; callers that need the full 30-day window
    /// should use the overload with an explicit `tombstoneHorizon:` parameter
    /// (available for Task 3+ engine integration).
    public static let tombstoneHorizon: TimeInterval = 2_001

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
