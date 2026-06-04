import Foundation

/// An editable structured config value. The in-memory model that structured
/// editors bind to, independent of the on-disk format. Numbers keep their raw
/// lexeme so `1` and `1.0` round-trip exactly.
public indirect enum ConfigValue: Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case array([ConfigValue])
    case object([ConfigEntry])
}

/// One ordered key → value pair inside a `.object`.
public struct ConfigEntry: Equatable, Sendable {
    public var key: String
    public var value: ConfigValue
    public init(key: String, value: ConfigValue) {
        self.key = key
        self.value = value
    }
}

/// A pluggable config format: text ⇄ structured `ConfigValue`. Conformers are
/// registered in `ConfigRegistry` so new formats drop in without touching the UI.
public protocol ConfigFormat: Sendable {
    /// Stable identifier (e.g. "json").
    static var identifier: String { get }
    /// Lower-cased file extensions this format claims (e.g. ["json"]).
    static var fileExtensions: Set<String> { get }
    static func parse(_ text: String) throws -> ConfigValue
    static func serialize(_ value: ConfigValue) throws -> String
}

/// Error surfaced when a format can't parse the given text.
public struct ConfigParseError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
