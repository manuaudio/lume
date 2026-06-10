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
    private var depth = 0
    /// Deeper nesting than any sane config file; prevents a stack overflow on
    /// adversarial input (the parser recurses once per nesting level).
    private static let maxDepth = 256

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
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else {
            throw ConfigParseError("nesting exceeds \(Self.maxDepth) levels")
        }
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
        let first = try parseHexCodeUnit()
        // High surrogate: must be immediately followed by an escaped low
        // surrogate (\uDC00–\uDFFF); the pair combines into one scalar.
        if (0xD800...0xDBFF).contains(first) {
            guard i + 1 < scalars.count, scalars[i] == "\\", scalars[i + 1] == "u" else {
                throw ConfigParseError("unpaired high surrogate \\u\(String(format: "%04X", first))")
            }
            i += 2 // consume \u
            let second = try parseHexCodeUnit()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw ConfigParseError("expected low surrogate, got \\u\(String(format: "%04X", second))")
            }
            let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(code) else {
                throw ConfigParseError("invalid surrogate pair")
            }
            return Character(scalar)
        }
        // A lone low surrogate is never a valid scalar.
        guard !(0xDC00...0xDFFF).contains(first), let scalar = Unicode.Scalar(first) else {
            throw ConfigParseError("unpaired low surrogate \\u\(String(format: "%04X", first))")
        }
        return Character(scalar)
    }

    private mutating func parseHexCodeUnit() throws -> UInt32 {
        guard i + 4 <= scalars.count else { throw ConfigParseError("short \\u escape") }
        let hex = String(scalars[i..<i + 4])
        guard let code = UInt32(hex, radix: 16) else {
            throw ConfigParseError("invalid \\u escape \(hex)")
        }
        i += 4
        return code
    }

    private mutating func parseBool() throws -> Bool {
        if peek() == "t" { try parseLiteral("true"); return true }
        try parseLiteral("false"); return false
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        while let c = peek(), "0123456789+-.eE".contains(c) { i += 1 }
        guard i > start else { throw ConfigParseError("invalid number at \(start)") }
        let lexeme = String(scalars[start..<i])
        guard Self.isValidJSONNumber(lexeme) else {
            throw ConfigParseError("invalid number '\(lexeme)' at \(start)")
        }
        return lexeme
    }

    /// Strict JSON number grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
    /// The greedy charset scan above accepts lexemes like `1.2.3` or `--1`;
    /// rejecting them here keeps serialized output valid JSON.
    private static func isValidJSONNumber(_ s: String) -> Bool {
        var rest = Substring(s)
        func digit() -> Bool {
            guard let c = rest.first, c.isASCII, c.isNumber else { return false }
            rest.removeFirst()
            return true
        }
        if rest.first == "-" { rest.removeFirst() }
        // Integer part: 0, or a non-zero digit followed by more digits.
        guard let lead = rest.first else { return false }
        guard digit() else { return false }
        if lead != "0" { while digit() {} }
        // Optional fraction: '.' then 1+ digits.
        if rest.first == "." {
            rest.removeFirst()
            guard digit() else { return false }
            while digit() {}
        }
        // Optional exponent: e/E, optional sign, then 1+ digits.
        if rest.first == "e" || rest.first == "E" {
            rest.removeFirst()
            if rest.first == "+" || rest.first == "-" { rest.removeFirst() }
            guard digit() else { return false }
            while digit() {}
        }
        return rest.isEmpty
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
