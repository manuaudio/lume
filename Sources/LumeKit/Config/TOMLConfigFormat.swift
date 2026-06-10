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
        return buildTable(entries).convert()
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
            // No ConfigValue date type — keep the textual form (stable round-trip).
            return .string(value.debugDescription)
        }
    }

    private static func buildTable(_ entries: [ConfigEntry]) -> TOMLTable {
        let table = TOMLTable()
        for entry in entries {
            table[entry.key] = tomlValue(entry.value)
        }
        return table
    }

    private static func tomlValue(_ value: ConfigValue) -> TOMLValueConvertible {
        switch value {
        case let .string(s): return s
        case let .number(n):
            if !n.contains("."), !n.lowercased().contains("e"), let i = Int(n) { return i }
            return Double(n) ?? 0
        case let .bool(b): return b
        case .null: return ""   // TOML has no null; closest stable mapping is empty string
        case let .date(lexeme): return lexeme   // refined to native TOML dates in Task 30
        case let .data(base64): return base64   // TOML has no binary type; base64 text as string
        case let .array(items): return TOMLArray(items.map(tomlValue))
        case let .object(entries): return buildTable(entries)
        }
    }
}
