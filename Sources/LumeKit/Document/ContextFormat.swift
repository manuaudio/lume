import Foundation

/// How `ContextAssembler` wraps file contents for an LLM paste.
public enum ContextFormat: String, CaseIterable, Sendable {
    /// `<documents><document path="…">…</document></documents>` — Claude-preferred.
    case xml
    /// `## path` + a language-fenced code block — portable across chatbots.
    case markdown

    /// Short label for menus/pickers.
    public var label: String {
        switch self {
        case .xml: return "XML"
        case .markdown: return "Markdown"
        }
    }
}
