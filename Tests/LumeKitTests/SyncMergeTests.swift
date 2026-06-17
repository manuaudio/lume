import Testing
import Foundation
@testable import LumeKit

struct SyncMergeTests {
    // Fixed clock points so timestamps are deterministic.
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)
    private let now = Date(timeIntervalSince1970: 3_000)

    private func fav(_ ref: String, path: String = "/p", dir: Bool = false,
                     at: Date, deleted: Bool = false) -> RemoteFavoriteRecord {
        let parts = ref.split(separator: ":", maxSplits: 2).map(String.init)
        return RemoteFavoriteRecord(ref: ref, sourceKind: parts[0], sourceKey: parts[1],
                                    path: path, isDirectory: dir, updatedAt: at, deleted: deleted)
    }
    private func doc(_ favs: [RemoteFavoriteRecord] = [], _ hosts: [ManualHostRecord] = []) -> SyncDocument {
        SyncDocument(schemaVersion: 1, remoteFavorites: favs, manualHosts: hosts)
    }

    @Test func newLocalItemAppearsStampedNow() {
        let out = SyncMerge.reconcile(baseline: doc(), local: doc([fav("ssh:w:/a", at: .distantPast)]),
                                      incoming: doc(), now: now)
        #expect(out.remoteFavorites.count == 1)
        #expect(out.remoteFavorites[0].updatedAt == now)
        #expect(out.remoteFavorites[0].deleted == false)
    }

    @Test func newIncomingItemAppears() {
        let out = SyncMerge.reconcile(baseline: doc(), local: doc(),
                                      incoming: doc([fav("ssh:w:/a", at: t2)]), now: now)
        #expect(out.remoteFavorites.map(\.ref) == ["ssh:w:/a"])
        #expect(out.remoteFavorites[0].updatedAt == t2)
    }

    @Test func unchangedItemKeepsBaselineTimestamp() {
        let b = doc([fav("ssh:w:/a", at: t1)])
        let out = SyncMerge.reconcile(baseline: b, local: doc([fav("ssh:w:/a", at: .distantPast)]),
                                      incoming: b, now: now)
        #expect(out.remoteFavorites[0].updatedAt == t1)   // not re-stamped
    }

    @Test func localEditBeatsOlderIncoming() {
        let b = doc([fav("ssh:w:/a", path: "/old", at: t1)])
        let local = doc([fav("ssh:w:/a", path: "/NEW", at: .distantPast)])    // path changed
        let incoming = doc([fav("ssh:w:/a", path: "/old", at: t1)])
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].path == "/NEW")
        #expect(out.remoteFavorites[0].updatedAt == now)
    }

    @Test func newerIncomingBeatsUnchangedLocal() {
        let b = doc([fav("ssh:w:/a", path: "/old", at: t1)])
        let local = doc([fav("ssh:w:/a", path: "/old", at: .distantPast)])    // unchanged
        let incoming = doc([fav("ssh:w:/a", path: "/REMOTE", at: t2)])        // newer edit elsewhere
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].path == "/REMOTE")
    }

    @Test func localDeleteTombstonesAndBeatsStaleIncoming() {
        let b = doc([fav("ssh:w:/a", at: t1)])
        let local = doc()                                   // removed locally
        let incoming = doc([fav("ssh:w:/a", at: t1)])       // peer still has the old copy
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites.count == 1)
        #expect(out.remoteFavorites[0].deleted == true)     // tombstone retained
        #expect(out.remoteFavorites[0].updatedAt == now)
    }

    @Test func tombstoneBeatsStaleReadd() {
        let b = doc([fav("ssh:w:/a", at: t2, deleted: true)])   // already a tombstone
        let local = doc()                                        // still absent locally
        let incoming = doc([fav("ssh:w:/a", at: t1)])            // stale re-add (older)
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].deleted == true)          // stays deleted
    }

    @Test func freshReaddBeatsTombstone() {
        let b = doc([fav("ssh:w:/a", at: t1, deleted: true)])
        let local = doc()
        let incoming = doc([fav("ssh:w:/a", at: t2)])            // re-added later
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: incoming, now: now)
        #expect(out.remoteFavorites[0].deleted == false)
    }

    @Test func concurrentIndependentItemsBothSurvive() {
        let out = SyncMerge.reconcile(
            baseline: doc(),
            local: doc([fav("ssh:w:/a", at: .distantPast)]),
            incoming: doc([fav("ssh:w:/b", at: t2)]),
            now: now)
        #expect(Set(out.remoteFavorites.map(\.ref)) == ["ssh:w:/a", "ssh:w:/b"])
    }

    @Test func oldTombstonesArePruned() {
        // now is t(3_000); the horizon is 30 days, so the tombstone must be
        // more than 30 days BEFORE now to prune (age > 2_592_000 s).
        let ancient = Date(timeIntervalSince1970: 3_000 - (31 * 24 * 3600))
        let b = doc([fav("ssh:w:/a", at: ancient, deleted: true)])
        let out = SyncMerge.reconcile(baseline: b, local: doc(), incoming: doc(), now: now)
        #expect(out.remoteFavorites.isEmpty)                    // pruned
    }

    @Test func emptyIncomingPreservesLocal() {
        let b = doc([fav("ssh:w:/a", at: t1)])
        let local = doc([fav("ssh:w:/a", at: .distantPast)])    // unchanged
        let out = SyncMerge.reconcile(baseline: b, local: local, incoming: doc(), now: now)
        #expect(out.remoteFavorites.map(\.ref) == ["ssh:w:/a"])
    }

    @Test func manualHostsReconcileByAlias() {
        let h = ManualHostRecord(alias: "web1", hostname: "10.0.0.5", user: "deploy",
                                 port: 22, identityFile: nil, updatedAt: .distantPast, deleted: false)
        let out = SyncMerge.reconcile(baseline: doc(), local: doc([], [h]),
                                      incoming: doc(), now: now)
        #expect(out.manualHosts.map(\.alias) == ["web1"])
        #expect(out.manualHosts[0].updatedAt == now)
    }
}
