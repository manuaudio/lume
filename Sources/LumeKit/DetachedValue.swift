import Foundation

/// Runs `work` off the current actor (via `Task.detached`) and returns its
/// value — or nil if the SURROUNDING task was cancelled while awaiting (e.g. a
/// SwiftUI `.task(id:)` restarted because its id changed, or the view left the
/// hierarchy). Callers treat nil as "stale: do not assign this result to @State".
///
/// The detached work itself is not cancelled (it runs to completion and its
/// value is discarded); the guard protects the ASSIGNMENT, which is what shows
/// the wrong file's data when rapid loads race.
public func detachedValue<T: Sendable>(
    priority: TaskPriority? = nil,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let value = await Task.detached(priority: priority) { await work() }.value
    return Task.isCancelled ? nil : value
}
