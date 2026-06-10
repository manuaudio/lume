import Foundation

/// JSON parsing/serialization that preserves object key order (Foundation's
/// `JSONSerialization` does not), so round-tripping a config file doesn't
/// scramble the user's keys.
public enum JSONConfigFormat: ConfigFormat {
    public static let identifier = "json"
    public static let fileExtensions: Set<String> = ["json"]

    public static func parse(_ text: String) throws -> ConfigValue {
        var parser = JSONParser(text)
        let value = try parser.parseDocument()
        return value
    }

    public static func serialize(_ value: ConfigValue) throws -> String {
        var out = ""
        write(value, indent: 0, into: &out)
        return out
    }

    private static func write(_ value: ConfigValue, indent: Int, into out: inout String) {
        switch value {
        case let .string(s):
            out.append(encodeString(s))
        case let .number(n):
            out.append(n)
        case let .bool(b):
            out.append(b ? "true" : "false")
        case .null:
            out.append("null")
        case let .date(d):
            // JSON has no date or binary types; both degrade to strings.
            out.append(encodeString(d))
        case let .data(d):
            out.append(encodeString(d))
        case let .array(items):
            if items.isEmpty { out.append("[]"); return }
            out.append("[\n")
            let pad = String(repeating: "  ", count: indent + 1)
            for (idx, item) in items.enumerated() {
                out.append(pad)
                write(item, indent: indent + 1, into: &out)
                out.append(idx == items.count - 1 ? "\n" : ",\n")
            }
            out.append(String(repeating: "  ", count: indent)); out.append("]")
        case let .object(entries):
            if entries.isEmpty { out.append("{}"); return }
            out.append("{\n")
            let pad = String(repeating: "  ", count: indent + 1)
            for (idx, entry) in entries.enumerated() {
                out.append(pad)
                out.append(encodeString(entry.key))
                out.append(": ")
                write(entry.value, indent: indent + 1, into: &out)
                out.append(idx == entries.count - 1 ? "\n" : ",\n")
            }
            out.append(String(repeating: "  ", count: indent)); out.append("}")
        }
    }

    private static func encodeString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if let scalar = c.unicodeScalars.first, scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.append(c)
                }
            }
        }
        out.append("\"")
        return out
    }
}

/// A minimal recursive-descent JSON parser that keeps object keys in source order.
private struct JSONParser {
    private let scalars: [Character]
    private var i = 0

    init(_ text: String) { scalars = Array(text) }

    mutating func parseDocument() throws -> ConfigValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        if i < scalars.count {
            throw ConfigParseError("unexpected trailing content at \(i)")
        }
        return value
    }

    private mutating func parseValue() throws -> ConfigValue {
        skipWhitespace()
        guard let c = peek() else { throw ConfigParseError("unexpected end of input") }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseLiteral("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func parseObject() throws -> ConfigValue {
        i += 1 // consume {
        var entries: [ConfigEntry] = []
        skipWhitespace()
        if peek() == "}" { i += 1; return .object(entries) }
        while true {
            skipWhitespace()
            guard peek() == "\"" else { throw ConfigParseError("expected string key at \(i)") }
            let key = try parseString()
            skipWhitespace()
            guard peek() == ":" else { throw ConfigParseError("expected ':' at \(i)") }
            i += 1
            let value = try parseValue()
            entries.append(ConfigEntry(key: key, value: value))
            skipWhitespace()
            switch peek() {
            case ",": i += 1
            case "}": i += 1; return .object(entries)
            default: throw ConfigParseError("expected ',' or '}' at \(i)")
            }
        }
    }

    private mutating func parseArray() throws -> ConfigValue {
        i += 1 // consume [
        var items: [ConfigValue] = []
        skipWhitespace()
        if peek() == "]" { i += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case ",": i += 1
            case "]": i += 1; return .array(items)
            default: throw ConfigParseError("expected ',' or ']' at \(i)")
            }
        }
    }

    private mutating func parseString() throws -> String {
        i += 1 // consume opening quote
        var out = ""
        while let c = peek() {
            i += 1
            if c == "\"" { return out }
            if c == "\\" {
                guard let esc = peek() else { throw ConfigParseError("dangling escape") }
                i += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u": out.append(try parseUnicodeEscape())
                default: throw ConfigParseError("invalid escape \\\(esc)")
                }
            } else {
                out.append(c)
            }
        }
        throw ConfigParseError("unterminated string")
    }

    private mutating func parseUnicodeEscape() throws -> Character {
        guard i + 4 <= scalars.count else { throw ConfigParseError("short \\u escape") }
        let hex = String(scalars[i..<i + 4])
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
            throw ConfigParseError("invalid \\u escape \(hex)")
        }
        i += 4
        return Character(scalar)
    }

    private mutating func parseBool() throws -> Bool {
        if peek() == "t" { try parseLiteral("true"); return true }
        try parseLiteral("false"); return false
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        while let c = peek(), "0123456789+-.eE".contains(c) { i += 1 }
        guard i > start else { throw ConfigParseError("invalid number at \(start)") }
        return String(scalars[start..<i])
    }

    private mutating func parseLiteral(_ literal: String) throws {
        for expected in literal {
            guard peek() == expected else { throw ConfigParseError("expected '\(literal)' at \(i)") }
            i += 1
        }
    }

    private func peek() -> Character? { i < scalars.count ? scalars[i] : nil }

    private mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\n" || c == "\t" || c == "\r" { i += 1 }
    }
}
