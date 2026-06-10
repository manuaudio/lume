import Foundation
import TOMLKit

/// TOML parsing/serialization backed by TOMLKit (toml++). A TOML document's root
/// is always a table, so serialization requires a `.object` root. Comments aren't
/// preserved across a structured edit — use the raw-source toggle to keep them.
public enum TOMLConfigFormat: ConfigFormat {
    public static let identifier = "toml"
    public static let fileExtensions: Set<String> = ["toml"]

    public static func parse(_ text: String) throws -> ConfigValue {
        do {
            let table = try TOMLTable(string: text)
            return convert(table)
        } catch {
            throw ConfigParseError("invalid TOML: \(error)")
        }
    }

    public static func serialize(_ value: ConfigValue) throws -> String {
        guard case let .object(entries) = value else {
            throw ConfigParseError("TOML root must be a table")
        }
        return try buildTable(entries).convert()
    }

    private static func convert(_ value: TOMLValueConvertible) -> ConfigValue {
        switch value.type {
        case .table:
            let table = value.table ?? TOMLTable()
            return .object(table.keys.compactMap { key in
                table[key].map { ConfigEntry(key: key, value: convert($0)) }
            })
        case .array:
            return .array((value.array ?? []).map(convert))
        case .string:
            return .string(value.string ?? "")
        case .int:
            return .number(String(value.int ?? 0))
        case .double:
            return .number(String(value.double ?? 0))
        case .bool:
            return .bool(value.bool ?? false)
        case .date, .time, .dateTime:
            // Keep the TOML lexeme so serialization can emit a native
            // (unquoted) date/time instead of retyping it to a string.
            return .date(value.debugDescription)
        }
    }

    private static func buildTable(_ entries: [ConfigEntry]) throws -> TOMLTable {
        let table = TOMLTable()
        for entry in entries {
            table[entry.key] = try tomlValue(entry.value)
        }
        return table
    }

    private static func tomlValue(_ value: ConfigValue) throws -> TOMLValueConvertible {
        switch value {
        case let .string(s): return s
        case let .number(n):
            if !n.contains("."), !n.lowercased().contains("e"), let i = Int(n) { return i }
            if let d = Double(n) { return d }
            throw ConfigParseError("not a valid TOML number: '\(n)'")
        case let .bool(b): return b
        case .null: return ""   // TOML has no null; closest stable mapping is empty string
        case let .date(lexeme):
            // Re-parse the lexeme through TOMLKit so it serializes as a native
            // date/time. Copy the value structs out — the probe table is temporary.
            guard let probe = try? TOMLTable(string: "v = \(lexeme)"), let v = probe["v"] else {
                throw ConfigParseError("not a valid TOML date/time: '\(lexeme)'")
            }
            if let dateTime = v.dateTime { return dateTime }
            if let date = v.date { return date }
            if let time = v.time { return time }
            throw ConfigParseError("not a valid TOML date/time: '\(lexeme)'")
        case let .data(base64):
            return base64   // TOML has no binary type; keep the base64 text as a string
        case let .array(items): return TOMLArray(try items.map(tomlValue))
        case let .object(entries): return try buildTable(entries)
        }
    }
}
