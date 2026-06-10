import Foundation

/// A monotonic generation counter that guards against stale async completions:
/// take a token (`advance()`) before suspending, and apply results only if
/// `isCurrent(token)` after resuming. Any later `advance()` invalidates every
/// earlier token.
public struct Generation: Equatable, Sendable {
    private var value = 0
    public init() {}

    /// Invalidate every outstanding token and return a fresh one.
    @discardableResult
    public mutating func advance() -> Int {
        value += 1
        return value
    }

    /// True while `token` is the latest generation (no `advance()` since).
    public func isCurrent(_ token: Int) -> Bool { token == value }
}
