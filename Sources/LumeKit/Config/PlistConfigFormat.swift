import Foundation

/// XML property-list parsing/serialization that preserves dict key order
/// (`PropertyListSerialization` returns unordered dictionaries). Binary plists
/// aren't handled — the structured view falls back to raw for those.
public enum PlistConfigFormat: ConfigFormat {
    public static let identifier = "plist"
    public static let fileExtensions: Set<String> = ["plist"]

    public static func parse(_ text: String) throws -> ConfigValue {
        guard let data = text.data(using: .utf8) else {
            throw ConfigParseError("not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = PlistBuilder()
        parser.delegate = delegate
        let ok = parser.parse()
        if let failure = delegate.failure { throw ConfigParseError(failure) }
        guard ok, let root = delegate.root else {
            throw ConfigParseError("invalid plist XML")
        }
        return root
    }

    public static func serialize(_ value: ConfigValue) throws -> String {
        var body = ""
        write(value, indent: 1, into: &body)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)</plist>
        """
    }

    private static func write(_ value: ConfigValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "    ", count: indent)
        switch value {
        case let .string(s):
            out.append("\(pad)<string>\(escape(s))</string>\n")
        case let .number(n):
            let tag = n.contains(".") || n.lowercased().contains("e") ? "real" : "integer"
            out.append("\(pad)<\(tag)>\(n)</\(tag)>\n")
        case let .bool(b):
            out.append("\(pad)<\(b ? "true" : "false")/>\n")
        case .null:
            // plist has no null; represent as an empty string to keep round-trips lossless-ish.
            out.append("\(pad)<string></string>\n")
        case let .date(d):
            out.append("\(pad)<date>\(escape(d))</date>\n")
        case let .data(d):
            out.append("\(pad)<data>\(escape(d))</data>\n")
        case let .array(items):
            if items.isEmpty { out.append("\(pad)<array/>\n"); return }
            out.append("\(pad)<array>\n")
            for item in items { write(item, indent: indent + 1, into: &out) }
            out.append("\(pad)</array>\n")
        case let .object(entries):
            if entries.isEmpty { out.append("\(pad)<dict/>\n"); return }
            out.append("\(pad)<dict>\n")
            let kpad = String(repeating: "    ", count: indent + 1)
            for entry in entries {
                out.append("\(kpad)<key>\(escape(entry.key))</key>\n")
                write(entry.value, indent: indent + 1, into: &out)
            }
            out.append("\(pad)</dict>\n")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Event-driven XMLParser delegate that builds a `ConfigValue` tree, preserving
/// document order. Containers are pushed on a stack; `<key>` names the next
/// value to be inserted into the enclosing dict.
private final class PlistBuilder: NSObject, XMLParserDelegate {
    private enum Container {
        case dict(entries: [ConfigEntry], pendingKey: String?)
        case array(items: [ConfigValue])
    }

    private(set) var root: ConfigValue?
    private(set) var failure: String?
    private var stack: [Container] = []
    private var text = ""
    /// True while inside a leaf element (`string`/`integer`/`real`/`key`) so we
    /// accumulate character data only where it's meaningful.
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "plist": break
        case "dict": stack.append(.dict(entries: [], pendingKey: nil))
        case "array": stack.append(.array(items: []))
        case "true": emit(.bool(true))
        case "false": emit(.bool(false))
        case "key", "string", "integer", "real", "data", "date":
            text = ""
            capturing = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    /// Defensive: the delegate contract routes `<![CDATA[…]]>` here. Apple's
    /// Foundation falls back to `foundCharacters` when this is unimplemented,
    /// but that fallback is undocumented — handle CDATA explicitly.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard capturing else { return }
        guard let decoded = String(data: CDATABlock, encoding: .utf8) else {
            failure = "CDATA block is not valid UTF-8"
            return
        }
        text += decoded
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "key":
            capturing = false
            guard case let .dict(entries, _)? = stack.last else {
                failure = "<key> outside a <dict>"; return
            }
            stack[stack.count - 1] = .dict(entries: entries, pendingKey: text)
        case "string": capturing = false; emit(.string(text))
        case "integer", "real": capturing = false; emit(.number(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "data": capturing = false; emit(.data(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "date": capturing = false; emit(.date(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "dict":
            guard case let .dict(entries, pending)? = stack.popLast() else {
                failure = "unbalanced </dict>"; return
            }
            if pending != nil { failure = "dangling <key> with no value" }
            emit(.object(entries))
        case "array":
            guard case let .array(items)? = stack.popLast() else {
                failure = "unbalanced </array>"; return
            }
            emit(.array(items))
        default: break
        }
    }

    /// Insert a finished value into its parent container, or set it as root.
    private func emit(_ value: ConfigValue) {
        guard !stack.isEmpty else { root = value; return }
        switch stack[stack.count - 1] {
        case .dict(var entries, let pendingKey):
            guard let key = pendingKey else { failure = "value with no preceding <key>"; return }
            entries.append(ConfigEntry(key: key, value: value))
            stack[stack.count - 1] = .dict(entries: entries, pendingKey: nil)
        case .array(var items):
            items.append(value)
            stack[stack.count - 1] = .array(items: items)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        if failure == nil { failure = error.localizedDescription }
    }
}
