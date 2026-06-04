import Foundation

/// Central, extensible list of structured config formats. A new format becomes
/// available app-wide by adding its type here — no UI changes required.
public enum ConfigRegistry {
    /// All registered formats, in priority order.
    public static let formats: [any ConfigFormat.Type] = [
        JSONConfigFormat.self,
        PlistConfigFormat.self,
        YAMLConfigFormat.self,
        TOMLConfigFormat.self,
    ]

    /// The format claiming `ext` (case-insensitive), or nil.
    public static func format(forExtension ext: String) -> (any ConfigFormat.Type)? {
        let key = ext.lowercased()
        return formats.first { $0.fileExtensions.contains(key) }
    }

    /// The format for a filename, resolved by its extension.
    public static func format(forFilename name: String) -> (any ConfigFormat.Type)? {
        format(forExtension: (name as NSString).pathExtension)
    }
}
