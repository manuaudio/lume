import Foundation
import LumeKit

/// The per-backend lifecycle behind a `RemoteSession`: SSH and GitHub each
/// implement this; `RemoteSession` owns the source-agnostic tree state above.
@MainActor
protocol RemoteConnection: AnyObject {
    var sourceID: SourceID { get }
    /// What the switcher/header shows ("web1", "owner/repo").
    var displayName: String { get }
    /// Establish the connection; returns the absolute root path to browse.
    func connect() async throws -> String
    /// Tear down (best-effort; no throw).
    func disconnect() async
    /// Human message for an error thrown by this backend's source/transport.
    func userMessage(for error: Error) -> String
}
