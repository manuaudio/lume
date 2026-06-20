import Foundation

/// A set of config files that share a filename — i.e. copies of "the same"
/// logical config living on different sources or in different directories.
public struct ConfigGroup: Identifiable, Equatable, Sendable {
    /// Lowercased filename, e.g. "claude.md" or ".env".
    public let key: String
    public let copies: [ConfigFile]

    public init(key: String, copies: [ConfigFile]) {
        self.key = key
        self.copies = copies
    }

    public var id: String { key }
}

public enum ConfigInventory {
    /// Group config files by lowercased filename, preserving first-appearance
    /// order of each filename.
    public static func group(_ files: [ConfigFile]) -> [ConfigGroup] {
        var order: [String] = []
        var buckets: [String: [ConfigFile]] = [:]
        for file in files {
            let key = file.name.lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(file)
        }
        return order.map { ConfigGroup(key: $0, copies: buckets[$0] ?? []) }
    }
}
