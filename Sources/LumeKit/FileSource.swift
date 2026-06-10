import Foundation

/// A backend that can list, read, and write text resources. Local disk and
/// SSH hosts both implement this; the editor and (remote) tree code work
/// against it instead of assuming local URLs.
public protocol FileSource: Sendable {
    var id: SourceID { get }
    /// Children of `path`, filtered/sorted with the same rules as the local
    /// sidebar (ignored names, dotfile policy, folders first).
    func list(_ path: String, includeHidden: Bool) async throws -> [ResourceNode]
    /// The resource's contents as UTF-8 text.
    func read(_ path: String) async throws -> String
    /// Replace the resource's contents atomically (a reader never observes a
    /// partial write), preserving its permissions.
    func write(_ text: String, to path: String) async throws
    func stat(_ path: String) async throws -> ResourceMeta
}
