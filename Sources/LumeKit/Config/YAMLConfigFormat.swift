import Foundation
import Yams

/// YAML parsing/serialization backed by Yams' order-preserving `Node` API.
/// Comments are not preserved across a structured edit (Yams discards them) —
/// the raw-source toggle is the way to keep them.
public enum YAMLConfigFormat: ConfigFormat {
    public static let identifier = "yaml"
    public static let fileExtensions: Set<String> = ["yaml", "yml"]

    public static func parse(_ text: String) throws -> ConfigValue {
        do {
            guard let node = try Yams.compose(yaml: text) else { return .null }
            return convert(node)
        } catch {
            throw ConfigParseError("invalid YAML: \(error)")
        }
    }

    public static func serialize(_ value: ConfigValue) throws -> String {
        do {
            return try Yams.serialize(node: build(value))
        } catch {
            throw ConfigParseError("YAML serialize failed: \(error)")
        }
    }

    private static func convert(_ node: Node) -> ConfigValue {
        if let mapping = node.mapping {
            return .object(mapping.map { ConfigEntry(key: $0.key.string ?? "", value: convert($0.value)) })
        }
        if let sequence = node.sequence {
            return .array(sequence.map(convert))
        }
        // Scalar: resolve to the most specific ConfigValue, preserving the lexeme.
        if node.null != nil { return .null }
        if let b = node.bool { return .bool(b) }
        if node.int != nil || node.float != nil { return .number(node.string ?? "0") }
        return .string(node.string ?? "")
    }

    private static func build(_ value: ConfigValue) -> Node {
        switch value {
        case let .string(s): return Node(s, Yams.Tag(.str), scalarStyle(for: s))
        case let .number(n):
            let tag: Yams.Tag.Name = (n.contains(".") || n.lowercased().contains("e")) ? .float : .int
            return Node(n, Yams.Tag(tag))
        case let .bool(b): return Node(b ? "true" : "false", Yams.Tag(.bool))
        case .null: return Node("null", Yams.Tag(.null))
        // Date lexemes stay plain — they re-resolve as YAML timestamps, which
        // `convert` maps back to text either way. Base64 blobs are strings here.
        case let .date(d): return Node(d, Yams.Tag(.str))
        case let .data(d): return Node(d, Yams.Tag(.str), scalarStyle(for: d))
        case let .array(items): return Node(items.map(build), Yams.Tag(.seq))
        case let .object(entries):
            return Node(entries.map { (Node($0.key, Yams.Tag(.str)), build($0.value)) }, Yams.Tag(.map))
        }
    }

    /// Plain-style emission drops the `!!str` tag, so a string whose text would
    /// re-resolve as another scalar type — "true", "no", "1.0", "null", "0x1F",
    /// "" — must be double-quoted or one save silently changes its type.
    /// Timestamps stay plain: `convert` maps them to `.string` on read anyway,
    /// so quoting would needlessly retype real YAML dates.
    private static func scalarStyle(for s: String) -> Node.Scalar.Style {
        let resolved = Resolver.default.resolveTag(of: Node(s))
        return (resolved == .str || resolved == .timestamp) ? .any : .doubleQuoted
    }
}
