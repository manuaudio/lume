import Foundation

/// A single config file found by `ConfigScanner` on one source.
public struct ConfigFile: Identifiable, Equatable, Sendable {
    public let ref: ResourceRef
    /// Byte size when known (from `stat`); nil if stat failed.
    public let size: Int64?

    public init(ref: ResourceRef, size: Int64?) {
        self.ref = ref
        self.size = size
    }

    public var id: ResourceRef { ref }
    public var name: String { ref.name }
}
